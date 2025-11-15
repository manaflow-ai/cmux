import http, {
  type IncomingHttpHeaders,
  type IncomingMessage,
  type Server as HttpServer,
  type ServerResponse,
} from "node:http";
import https from "node:https";
import http2, {
  type ClientHttp2Session,
  type Http2Server,
  type IncomingHttpHeaders as Http2IncomingHttpHeaders,
  type OutgoingHttpHeaders as Http2OutgoingHttpHeaders,
  type ServerHttp2Stream,
  type ServerOptions as Http2ServerOptions,
} from "node:http2";
import net, { type Socket } from "node:net";
import tls, { type TLSSocket } from "node:tls";
import { randomBytes, createHash } from "node:crypto";
import { URL } from "node:url";
import { pipeline as pipelineStream } from "node:stream/promises";
import type { Session, WebContents } from "electron";
import { isLoopbackHostname } from "@cmux/shared";
import type { Logger } from "./chrome-camouflage";

type CombinedIncomingHeaders = IncomingHttpHeaders | Http2IncomingHttpHeaders;

type ProxyServer = Http2Server & HttpServer;
type Http2ServerOptionsWithAllow = Http2ServerOptions & {
  allowHTTP1?: boolean;
};

const TASK_RUN_PREVIEW_PREFIX = "task-run-preview:";
const DEFAULT_PROXY_LOGGING_ENABLED = false;
const CMUX_DOMAINS = [
  "cmux.app",
  "cmux.sh",
  "cmux.dev",
  "cmux.local",
  "cmux.localhost",
  "autobuild.app",
] as const;

interface ProxyRoute {
  morphId: string;
  scope: string;
  domainSuffix: (typeof CMUX_DOMAINS)[number];
}

interface ProxyContext {
  username: string;
  password: string;
  route: ProxyRoute | null;
  session: Session;
  webContentsId: number;
  persistKey?: string;
}

interface ProxyTarget {
  url: URL;
  secure: boolean;
  connectPort: number;
}

type DownstreamDestination =
  | { kind: "http1"; res: ServerResponse }
  | { kind: "http2"; stream: ServerHttp2Stream };

interface ProxyClientRequest {
  method: string;
  headers: CombinedIncomingHeaders;
  body: NodeJS.ReadableStream;
  onAbort: (handler: () => void) => void;
}

interface ProxyUpstreamRequestOptions {
  target: ProxyTarget;
  method: string;
  headers: Record<string, string>;
  body: NodeJS.ReadableStream;
  destination: DownstreamDestination;
  preferHttp2: boolean;
  onAbort: (handler: () => void) => void;
  context: ProxyContext;
}

class Http2RequestAlreadyStartedError extends Error {
  constructor(message?: string) {
    super(message ?? "HTTP/2 upstream request already started");
    this.name = "Http2RequestAlreadyStartedError";
  }
}

interface ConfigureOptions {
  webContents: WebContents;
  initialUrl: string;
  persistKey?: string;
  logger: Logger;
}

let proxyServer: ProxyServer | null = null;
let proxyPort: number | null = null;
let proxyLogger: Logger | null = null;
let startingProxy: Promise<number> | null = null;
let proxyLoggingEnabled = DEFAULT_PROXY_LOGGING_ENABLED;
const hopByHopHeaders = new Set([
  "connection",
  "proxy-connection",
  "keep-alive",
  "upgrade",
  "transfer-encoding",
  "te",
  "trailer",
]);
const http2Sessions = new Map<string, ClientHttp2Session>();

export function setPreviewProxyLoggingEnabled(enabled: boolean): void {
  proxyLoggingEnabled = Boolean(enabled);
}

const contextsByUsername = new Map<string, ProxyContext>();
const contextsByWebContentsId = new Map<number, ProxyContext>();

function proxyLog(event: string, data?: Record<string, unknown>): void {
  if (!proxyLoggingEnabled) {
    return;
  }
  try {
    proxyLogger?.log("Preview proxy", { event, ...(data ?? {}) });
  } catch (error) {
    console.error("Failed to log preview proxy", error);
  }
}

function proxyWarn(event: string, data?: Record<string, unknown>): void {
  if (!proxyLoggingEnabled) {
    return;
  }
  try {
    proxyLogger?.warn("Preview proxy", { event, ...(data ?? {}) });
  } catch (error) {
    console.error("Failed to log preview proxy", error);
  }
}

export function isTaskRunPreviewPersistKey(
  key: string | undefined
): key is string {
  return typeof key === "string" && key.startsWith(TASK_RUN_PREVIEW_PREFIX);
}

export function getPreviewPartitionForPersistKey(
  key: string | undefined
): string | null {
  if (!isTaskRunPreviewPersistKey(key)) {
    return null;
  }
  const hash = createHash("sha256").update(key).digest("hex").slice(0, 24);
  return `persist:cmux-preview-${hash}`;
}

export function getProxyCredentialsForWebContents(
  id: number
): { username: string; password: string } | null {
  const context = contextsByWebContentsId.get(id);
  if (!context) return null;
  return { username: context.username, password: context.password };
}

export function releasePreviewProxy(webContentsId: number): void {
  const context = contextsByWebContentsId.get(webContentsId);
  if (!context) return;
  contextsByWebContentsId.delete(webContentsId);
  contextsByUsername.delete(context.username);
  proxyLog("reset-session-proxy", {
    webContentsId,
    persistKey: context.persistKey,
  });
  void context.session.setProxy({ mode: "direct" }).catch((err) => {
    console.error("Failed to reset preview proxy", err);
  });
}

export async function configurePreviewProxyForView(
  options: ConfigureOptions
): Promise<() => void> {
  const { webContents, initialUrl, persistKey, logger } = options;
  const route = deriveRoute(initialUrl);
  if (!route) {
    logger.warn("Preview proxy skipped; unable to parse cmux host", {
      url: initialUrl,
      persistKey,
    });
    return () => {};
  }

  const port = await ensureProxyServer(logger);
  const username = `wc-${webContents.id}-${randomBytes(4).toString("hex")}`;
  const password = randomBytes(12).toString("hex");

  const context: ProxyContext = {
    username,
    password,
    route,
    session: webContents.session,
    webContentsId: webContents.id,
    persistKey,
  };

  contextsByUsername.set(username, context);
  contextsByWebContentsId.set(webContents.id, context);

  try {
    await webContents.session.setProxy({
      proxyRules: `http=127.0.0.1:${port};https=127.0.0.1:${port}`,
      proxyBypassRules: "<-loopback>",
    });
  } catch (error) {
    contextsByUsername.delete(username);
    contextsByWebContentsId.delete(webContents.id);
    logger.warn("Failed to configure preview proxy", { error });
    throw error;
  }

  let cleanedUp = false;
  const cleanup = () => {
    if (cleanedUp) {
      return;
    }
    cleanedUp = true;
    releasePreviewProxy(webContents.id);
    proxyLog("released-context", {
      webContentsId: webContents.id,
      persistKey,
    });
  };

  webContents.once("destroyed", cleanup);
  proxyLog("configured-context", {
    webContentsId: webContents.id,
    persistKey,
    route,
  });
  return cleanup;
}

export function startPreviewProxy(logger: Logger): Promise<number> {
  return ensureProxyServer(logger);
}

async function ensureProxyServer(logger: Logger): Promise<number> {
  if (proxyPort && proxyServer) {
    return proxyPort;
  }
  if (startingProxy) {
    return startingProxy;
  }
  startingProxy = startProxyServer(logger);
  try {
    const port = await startingProxy;
    proxyPort = port;
    return port;
  } finally {
    startingProxy = null;
  }
}

async function startProxyServer(logger: Logger): Promise<number> {
  const startPort = 39385;
  const maxAttempts = 50;
  for (let i = 0; i < maxAttempts; i += 1) {
    const candidatePort = startPort + i;
    const server = http2.createServer(
      { allowHTTP1: true } as Http2ServerOptionsWithAllow
    ) as ProxyServer;
    attachServerHandlers(server);
    try {
      await listen(server, candidatePort);
      proxyServer = server;
      proxyLogger = logger;
      console.log(`[cmux-preview-proxy] listening on port ${candidatePort}`);
      logger.log("Preview proxy listening", { port: candidatePort });
      proxyLog("listening", { port: candidatePort });
      return candidatePort;
    } catch (error) {
      server.removeAllListeners();
      try {
        server.close();
      } catch (error) {
        console.error("Failed to close preview proxy server", error);
        // ignore close failure
      }
      if ((error as NodeJS.ErrnoException).code === "EADDRINUSE") {
        continue;
      }
      throw error;
    }
  }
  throw new Error("Unable to bind preview proxy port");
}

function listen(server: ProxyServer, port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const handleError = (error: Error) => {
      server.off("listening", handleListening);
      reject(error);
    };
    const handleListening = () => {
      server.off("error", handleError);
      resolve();
    };
    server.once("error", handleError);
    server.once("listening", handleListening);
    server.listen(port, "127.0.0.1");
  });
}

function attachServerHandlers(server: ProxyServer) {
  server.on("stream", handleHttp2Stream);
  server.on("request", handleHttpRequest);
  server.on("connect", handleConnect);
  server.on("upgrade", handleUpgrade);
  server.on("sessionError", (error) => {
    proxyLogger?.warn("Proxy HTTP/2 session error", { error });
  });
  server.on("clientError", (error, socket) => {
    proxyLogger?.warn("Proxy client error", { error });
    socket.end();
  });
}

function handleHttpRequest(req: IncomingMessage, res: ServerResponse) {
  const context = authenticateRequest(req.headers);
  if (!context) {
    respondProxyAuthRequired(res);
    return;
  }

  const target = parseProxyRequestTarget(req);
  if (!target) {
    proxyWarn("http-target-parse-failed", {
      url: req.url,
      host: req.headers.host,
    });
    res.writeHead(400);
    res.end("Bad Request");
    return;
  }

  const rewritten = rewriteTarget(target, context);
  proxyLog("http-request", {
    username: context.username,
    requestedHost: target.hostname,
    requestedPort: target.port,
    rewrittenHost: rewritten.url.hostname,
    rewrittenPort: rewritten.connectPort,
    persistKey: context.persistKey,
  });
  const client: ProxyClientRequest = {
    method: req.method ?? "GET",
    headers: req.headers,
    body: req,
    onAbort: (handler) => {
      let called = false;
      const invoke = () => {
        if (called) return;
        called = true;
        handler();
      };
      req.once("aborted", invoke);
      req.once("close", invoke);
      req.once("error", invoke);
    },
  };
  forwardHttpRequest(client, { kind: "http1", res }, rewritten, context);
}

function handleHttp2Stream(
  stream: ServerHttp2Stream,
  headers: Http2IncomingHttpHeaders
) {
  const context = authenticateRequest(headers);
  if (!context) {
    respondProxyAuthRequiredHttp2(stream);
    return;
  }

  const parsedMethod = headers[":method"];
  const method =
    typeof parsedMethod === "string" && parsedMethod.length > 0
      ? parsedMethod
      : "GET";
  if (method.toUpperCase() === "CONNECT") {
    handleHttp2Connect(stream, headers, context);
    return;
  }

  const target = parseHttp2RequestTarget(headers);
  if (!target) {
    proxyWarn("http2-target-parse-failed", {
      authority: headers[":authority"],
      path: headers[":path"],
    });
    respondHttp2Error(stream, 400, "Bad Request");
    return;
  }

  const rewritten = rewriteTarget(target, context);
  proxyLog("http2-request", {
    username: context.username,
    requestedHost: target.hostname,
    requestedPort: target.port,
    rewrittenHost: rewritten.url.hostname,
    rewrittenPort: rewritten.connectPort,
    persistKey: context.persistKey,
  });

  const client: ProxyClientRequest = {
    method,
    headers,
    body: stream,
    onAbort: (handler) => {
      let called = false;
      const invoke = () => {
        if (called) return;
        called = true;
        handler();
      };
      stream.once("aborted", invoke);
      stream.once("close", invoke);
      stream.once("error", invoke);
    },
  };

  forwardHttpRequest(client, { kind: "http2", stream }, rewritten, context);
}

function handleHttp2Connect(
  stream: ServerHttp2Stream,
  headers: Http2IncomingHttpHeaders,
  context: ProxyContext
) {
  const authority = headers[":authority"];
  if (typeof authority !== "string" || authority.length === 0) {
    respondHttp2Error(stream, 400, "Bad Request");
    return;
  }
  const target = parseConnectTarget(authority);
  if (!target) {
    proxyWarn("http2-connect-target-parse-failed", {
      authority,
    });
    respondHttp2Error(stream, 400, "Bad Request");
    return;
  }

  const targetUrl = new URL(`https://${target.hostname}`);
  targetUrl.port = String(target.port);
  const rewritten = rewriteTarget(targetUrl, context);
  proxyLog("http2-connect-request", {
    username: context.username,
    requestedHost: target.hostname,
    requestedPort: target.port,
    rewrittenHost: rewritten.url.hostname,
    rewrittenPort: rewritten.connectPort,
    persistKey: context.persistKey,
  });

  const upstream = net.connect(
    rewritten.connectPort,
    rewritten.url.hostname,
    () => {
      stream.respond({ ":status": 200 });
      stream.pipe(upstream);
      upstream.pipe(stream);
    }
  );

  upstream.on("error", (error) => {
    proxyLogger?.warn("HTTP/2 CONNECT upstream error", { error });
    respondHttp2Error(stream, 502, "Bad Gateway");
  });

  stream.on("error", () => {
    upstream.destroy();
  });
  stream.on("close", () => {
    upstream.destroy();
  });
}

function handleConnect(req: IncomingMessage, socket: Socket, head: Buffer) {
  const context = authenticateRequest(req.headers);
  if (!context) {
    respondProxyAuthRequiredSocket(socket);
    return;
  }

  const target = parseConnectTarget(req.url ?? "");
  if (!target) {
    proxyWarn("connect-target-parse-failed", {
      url: req.url,
    });
    socket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
    socket.end();
    return;
  }

  const targetUrl = new URL(`https://${target.hostname}`);
  targetUrl.port = String(target.port);
  const rewritten = rewriteTarget(targetUrl, context);

  proxyLog("connect-request", {
    username: context.username,
    requestedHost: target.hostname,
    requestedPort: target.port,
    rewrittenHost: rewritten.url.hostname,
    rewrittenPort: rewritten.connectPort,
    persistKey: context.persistKey,
  });
  const upstream = net.connect(rewritten.connectPort, rewritten.url.hostname, () => {
    socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    if (head.length > 0) {
      upstream.write(head);
    }
    upstream.pipe(socket);
    socket.pipe(upstream);
  });

  upstream.on("error", (error) => {
    proxyLogger?.warn("CONNECT upstream error", { error });
    socket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
    socket.end();
  });

  socket.on("error", () => {
    upstream.destroy();
  });
}

function handleUpgrade(req: IncomingMessage, socket: Socket, head: Buffer) {
  const context = authenticateRequest(req.headers);
  if (!context) {
    respondProxyAuthRequiredSocket(socket);
    return;
  }

  const target = parseProxyRequestTarget(req);
  if (!target) {
    proxyWarn("upgrade-target-parse-failed", {
      url: req.url,
      host: req.headers.host,
    });
    socket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
    socket.end();
    return;
  }

  const rewritten = rewriteTarget(target, context);
  proxyLog("upgrade-request", {
    username: context.username,
    requestedHost: target.hostname,
    requestedPort: target.port,
    rewrittenHost: rewritten.url.hostname,
    rewrittenPort: rewritten.connectPort,
    persistKey: context.persistKey,
  });
  forwardUpgradeRequest(req, socket, head, rewritten);
}

function authenticateRequest(
  headers: CombinedIncomingHeaders
): ProxyContext | null {
  const raw = headers["proxy-authorization"];
  if (typeof raw !== "string") {
    return null;
  }
  const match = raw.match(/^Basic\s+(.+)$/i);
  if (!match) return null;
  const decoded = Buffer.from(match[1], "base64").toString("utf8");
  const separatorIndex = decoded.indexOf(":");
  if (separatorIndex === -1) return null;
  const username = decoded.slice(0, separatorIndex);
  const password = decoded.slice(separatorIndex + 1);
  const context = contextsByUsername.get(username);
  if (!context || context.password !== password) {
    return null;
  }
  return context;
}

function respondProxyAuthRequired(res: ServerResponse) {
  res.writeHead(407, {
    "Proxy-Authenticate": 'Basic realm="Cmux Preview Proxy"',
  });
  res.end("Proxy Authentication Required");
}

function respondProxyAuthRequiredSocket(socket: Socket) {
  socket.write(
    'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="Cmux Preview Proxy"\r\n\r\n'
  );
  socket.end();
}

function respondProxyAuthRequiredHttp2(stream: ServerHttp2Stream) {
  if (stream.headersSent) {
    stream.close(http2.constants.NGHTTP2_REFUSED_STREAM);
    return;
  }
  stream.respond({
    ":status": 407,
    "proxy-authenticate": 'Basic realm="Cmux Preview Proxy"',
  });
  stream.end("Proxy Authentication Required");
}

function respondHttp2Error(
  stream: ServerHttp2Stream,
  statusCode: number,
  body: string
) {
  if (stream.headersSent) {
    stream.close(http2.constants.NGHTTP2_INTERNAL_ERROR);
    return;
  }
  stream.respond({
    ":status": statusCode,
  });
  stream.end(body);
}

function parseProxyRequestTarget(req: IncomingMessage): URL | null {
  try {
    if (req.url && /^[a-z]+:\/\//i.test(req.url)) {
      const normalized = req.url.replace(/^ws(s)?:\/\//i, (_match, secure) =>
        secure ? "https://" : "http://"
      );
      return new URL(normalized);
    }
    const host = req.headers.host;
    if (!host || !req.url) {
      return null;
    }
    return new URL(`http://${host}${req.url}`);
  } catch (error) {
    console.error("Failed to parse proxy request target", error);
    return null;
  }
}

function parseHttp2RequestTarget(
  headers: Http2IncomingHttpHeaders
): URL | null {
  try {
    const authority = headers[":authority"];
    const scheme = headers[":scheme"] ?? "https";
    const path = headers[":path"] ?? "/";
    if (typeof authority !== "string" || authority.length === 0) {
      return null;
    }
    const normalizedPath =
      typeof path === "string" && path.length > 0 ? path : "/";
    return new URL(`${scheme}://${authority}${normalizedPath}`);
  } catch (error) {
    console.error("Failed to parse HTTP/2 proxy request target", error);
    return null;
  }
}

function parseConnectTarget(
  input: string
): { hostname: string; port: number } | null {
  if (!input) return null;
  const [host, portString] = input.split(":");
  const port = Number.parseInt(portString ?? "", 10);
  if (!host || Number.isNaN(port)) {
    return null;
  }
  return { hostname: host, port };
}

function rewriteTarget(url: URL, context: ProxyContext): ProxyTarget {
  const rewritten = new URL(url.toString());
  let secure = rewritten.protocol === "https:";

  if (context.route && isLoopbackHostname(rewritten.hostname)) {
    const requestedPort = determineRequestedPort(url);
    rewritten.protocol = "https:";
    rewritten.hostname = buildCmuxHost(context.route, requestedPort);
    rewritten.port = "";
    secure = true;
  }

  const connectPort = Number.parseInt(rewritten.port, 10);
  const resolvedPort = Number.isNaN(connectPort)
    ? secure
      ? 443
      : 80
    : connectPort;

  return {
    url: rewritten,
    secure,
    connectPort: resolvedPort,
  };
}

function determineRequestedPort(url: URL): number {
  if (url.port) {
    const parsed = Number.parseInt(url.port, 10);
    if (!Number.isNaN(parsed) && parsed > 0) {
      return parsed;
    }
  }
  if (url.protocol === "https:" || url.protocol === "wss:") {
    return 443;
  }
  return 80;
}

function buildCmuxHost(route: ProxyRoute, port: number): string {
  const safePort = Number.isFinite(port) && port > 0 ? Math.floor(port) : 80;
  return `cmux-${route.morphId}-${route.scope}-${safePort}.${route.domainSuffix}`;
}

function forwardHttpRequest(
  client: ProxyClientRequest,
  destination: DownstreamDestination,
  target: ProxyTarget,
  context: ProxyContext
) {
  const requestHeaders = buildForwardHeaders(client.headers, target.url);
  const method = client.method ?? "GET";
  void proxyRequestUpstream({
    target,
    method,
    headers: requestHeaders,
    body: client.body,
    destination,
    preferHttp2: target.secure,
    onAbort: client.onAbort,
    context,
  }).catch((error) => {
    proxyWarn("http-forward-failed", {
      error,
      persistKey: context.persistKey,
      username: context.username,
      host: target.url.hostname,
      port: target.connectPort,
    });
    sendDownstreamFailure(destination, 502, "Bad Gateway");
  });
}

function forwardUpgradeRequest(
  clientReq: IncomingMessage,
  socket: Socket,
  head: Buffer,
  target: ProxyTarget
) {
  const { url, secure, connectPort } = target;
  const upstream: Socket | TLSSocket = secure
    ? tls.connect({
        host: url.hostname,
        port: connectPort,
        servername: url.hostname,
      })
    : net.connect(connectPort, url.hostname);

  const handleConnected = () => {
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries(clientReq.headers)) {
      if (!value) continue;
      if (key.toLowerCase() === "proxy-authorization") continue;
      headers[key] = Array.isArray(value) ? value.join(", ") : value;
    }
    headers.host = url.host;

    const lines = [
      `${clientReq.method ?? "GET"} ${url.pathname}${url.search} HTTP/1.1`,
    ];
    for (const [key, value] of Object.entries(headers)) {
      lines.push(`${key}: ${value}`);
    }
    lines.push("\r\n");
    upstream.write(lines.join("\r\n"));
    if (head.length > 0) {
      upstream.write(head);
    }

    upstream.pipe(socket);
    socket.pipe(upstream);
  };

  if (secure && upstream instanceof tls.TLSSocket) {
    upstream.once("secureConnect", handleConnected);
  } else {
    upstream.once("connect", handleConnected);
  }

  upstream.on("error", (error) => {
    proxyWarn("upgrade-upstream-error", {
      error,
      host: url.hostname,
      port: connectPort,
    });
    socket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
    socket.end();
  });

  socket.on("error", () => {
    upstream.destroy();
  });
}

function buildForwardHeaders(
  headers: CombinedIncomingHeaders,
  url: URL
): Record<string, string> {
  const normalized: Record<string, string> = {};
  for (const [rawKey, rawValue] of Object.entries(headers)) {
    if (!rawValue) continue;
    if (rawKey.startsWith(":")) continue;
    const key = rawKey.toLowerCase();
    if (key === "proxy-authorization") continue;
    if (hopByHopHeaders.has(key)) continue;
    if (Array.isArray(rawValue)) {
      normalized[key] = rawValue.join(", ");
    } else {
      normalized[key] = String(rawValue);
    }
  }
  normalized.host = url.host;
  return normalized;
}

function sanitizeUpstreamHeaders(
  headers: IncomingHttpHeaders | Http2IncomingHttpHeaders
): Record<string, string | string[]> {
  const sanitized: Record<string, string | string[]> = {};
  for (const [rawKey, rawValue] of Object.entries(headers)) {
    if (!rawValue) continue;
    if (rawKey.startsWith(":")) continue;
    const key = rawKey.toLowerCase();
    if (hopByHopHeaders.has(key)) continue;
    if (Array.isArray(rawValue)) {
      sanitized[key] = rawValue.map((value) => String(value));
    } else {
      sanitized[key] = String(rawValue);
    }
  }
  return sanitized;
}

function downstreamHeadersSent(destination: DownstreamDestination): boolean {
  return destination.kind === "http1"
    ? destination.res.headersSent
    : destination.stream.headersSent;
}

function getDownstreamWritable(
  destination: DownstreamDestination
): NodeJS.WritableStream {
  return destination.kind === "http1" ? destination.res : destination.stream;
}

function writeDownstreamResponse(
  destination: DownstreamDestination,
  statusCode: number,
  statusMessage: string,
  headers: Record<string, string | string[]>
) {
  if (downstreamHeadersSent(destination)) {
    return;
  }
  if (destination.kind === "http1") {
    if (statusMessage && statusMessage.length > 0) {
      destination.res.writeHead(statusCode, statusMessage, headers);
    } else {
      destination.res.writeHead(statusCode, headers);
    }
    return;
  }
  const responseHeaders: Http2OutgoingHttpHeaders = {
    ":status": statusCode,
  };
  for (const [key, value] of Object.entries(headers)) {
    const normalizedKey = key.toLowerCase();
    if (hopByHopHeaders.has(normalizedKey)) continue;
    if (Array.isArray(value)) {
      responseHeaders[normalizedKey] =
        normalizedKey === "set-cookie" ? value : value.join(", ");
    } else {
      responseHeaders[normalizedKey] = value;
    }
  }
  destination.stream.respond(responseHeaders);
}

function sendDownstreamFailure(
  destination: DownstreamDestination,
  statusCode: number,
  message: string
) {
  if (downstreamHeadersSent(destination)) {
    if (destination.kind === "http2") {
      destination.stream.close(http2.constants.NGHTTP2_INTERNAL_ERROR);
    } else {
      destination.res.end();
    }
    return;
  }
  if (destination.kind === "http1") {
    destination.res.writeHead(statusCode);
    destination.res.end(message);
  } else {
    destination.stream.respond({ ":status": statusCode });
    destination.stream.end(message);
  }
}

function buildHttpPath(url: URL): string {
  const path = `${url.pathname ?? ""}${url.search ?? ""}`;
  return path.length > 0 ? path : "/";
}

async function proxyRequestUpstream(
  options: ProxyUpstreamRequestOptions
): Promise<void> {
  if (options.preferHttp2 && options.target.secure) {
    try {
      const session = await ensureHttp2Session(options.target);
      try {
        await sendViaHttp2(session, options);
        return;
      } catch (error) {
        if (error instanceof Http2RequestAlreadyStartedError) {
          throw error;
        }
        proxyWarn("http2-request-error", {
          error,
          host: options.target.url.hostname,
          port: options.target.connectPort,
        });
      }
    } catch (error) {
      proxyWarn("http2-session-init-failed", {
        error,
        host: options.target.url.hostname,
        port: options.target.connectPort,
      });
    }
  }
  await sendViaHttp1(options);
}

async function sendViaHttp1(
  options: ProxyUpstreamRequestOptions
): Promise<void> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const safeResolve = () => {
      if (settled) return;
      settled = true;
      resolve();
    };
    const safeReject = (error: Error) => {
      if (settled) return;
      settled = true;
      reject(error);
    };
    const httpModule = options.target.secure ? https : http;
    const requestOptions = {
      protocol: options.target.secure ? "https:" : "http:",
      hostname: options.target.url.hostname,
      port: options.target.connectPort,
      method: options.method,
      path: buildHttpPath(options.target.url),
      headers: options.headers,
    };
    const proxyReq = httpModule.request(requestOptions, (proxyRes) => {
      const sanitizedHeaders = sanitizeUpstreamHeaders(proxyRes.headers);
      writeDownstreamResponse(
        options.destination,
        proxyRes.statusCode ?? 500,
        proxyRes.statusMessage ?? "",
        sanitizedHeaders
      );
      pipelineStream(proxyRes, getDownstreamWritable(options.destination))
        .then(safeResolve)
        .catch((error) => safeReject(error as Error));
    });

    proxyReq.on("error", (error) => {
      if (!downstreamHeadersSent(options.destination)) {
        sendDownstreamFailure(options.destination, 502, "Bad Gateway");
      }
      safeReject(error as Error);
    });

    options.onAbort(() => {
      proxyReq.destroy();
    });

    pipelineStream(options.body, proxyReq).catch((error) => {
      proxyReq.destroy(error as Error);
    });
  });
}

async function sendViaHttp2(
  session: ClientHttp2Session,
  options: ProxyUpstreamRequestOptions
): Promise<void> {
  return new Promise((resolve, reject) => {
    let settled = false;
    let responded = false;
    let requestStarted = false;
    const safeResolve = () => {
      if (settled) return;
      settled = true;
      resolve();
    };
    const safeReject = (error: Error) => {
      if (settled) return;
      settled = true;
      reject(error);
    };

    const headers: Http2OutgoingHttpHeaders = {
      ":method": options.method,
      ":path": buildHttpPath(options.target.url),
      ":scheme": options.target.secure ? "https" : "http",
      ":authority": options.target.url.host,
    };
    for (const [key, value] of Object.entries(options.headers)) {
      const normalizedKey = key.toLowerCase();
      if (normalizedKey === "host") continue;
      if (hopByHopHeaders.has(normalizedKey)) continue;
      headers[normalizedKey] = value;
    }

    const proxyReq = session.request(headers, { endStream: false });

    proxyReq.on("response", (responseHeaders) => {
      responded = true;
      const rawStatus = responseHeaders[":status"];
      const statusCode =
        typeof rawStatus === "number"
          ? rawStatus
          : Number(rawStatus ?? 502);
      const sanitizedHeaders = sanitizeUpstreamHeaders(responseHeaders);
      writeDownstreamResponse(
        options.destination,
        Number.isNaN(statusCode) ? 502 : statusCode,
        "",
        sanitizedHeaders
      );
      pipelineStream(proxyReq, getDownstreamWritable(options.destination))
        .then(safeResolve)
        .catch((error) => safeReject(error as Error));
    });

    proxyReq.on("error", (error) => {
      if (!downstreamHeadersSent(options.destination)) {
        sendDownstreamFailure(options.destination, 502, "Bad Gateway");
      }
      safeReject(
        requestStarted
          ? new Http2RequestAlreadyStartedError(error.message)
          : (error as Error)
      );
    });

    proxyReq.on("close", () => {
      if (!responded && !downstreamHeadersSent(options.destination)) {
        sendDownstreamFailure(options.destination, 502, "Bad Gateway");
        safeReject(
          new Http2RequestAlreadyStartedError(
            "HTTP/2 upstream closed before response"
          )
        );
      }
    });

    options.onAbort(() => {
      proxyReq.close(http2.constants.NGHTTP2_CANCEL);
    });

    requestStarted = true;
    pipelineStream(options.body, proxyReq).catch((error) => {
      proxyReq.destroy(error as Error);
    });
  });
}

function getHttp2SessionKey(target: ProxyTarget): string {
  return `${target.url.hostname}:${target.connectPort}`;
}

async function ensureHttp2Session(
  target: ProxyTarget
): Promise<ClientHttp2Session> {
  const key = getHttp2SessionKey(target);
  const existing = http2Sessions.get(key);
  if (existing && !existing.closed && !existing.destroyed) {
    return existing;
  }
  if (existing) {
    http2Sessions.delete(key);
    try {
      existing.close();
    } catch {
      // ignore
    }
  }
  return createHttp2Session(target, key);
}

function createHttp2Session(
  target: ProxyTarget,
  key: string
): Promise<ClientHttp2Session> {
  return new Promise((resolve, reject) => {
    const authority = `https://${target.url.hostname}:${target.connectPort}`;
    const session = http2.connect(authority, {
      servername: target.url.hostname,
    });
    const cleanup = () => {
      session.off("connect", handleConnect);
      session.off("error", handleError);
    };
    const handleError = (error: Error) => {
      cleanup();
      try {
        session.close();
      } catch {
        // ignore
      }
      reject(error);
    };
    const handleConnect = () => {
      cleanup();
      registerHttp2SessionLifecycle(session, key);
      http2Sessions.set(key, session);
      resolve(session);
    };
    session.once("error", handleError);
    session.once("connect", handleConnect);
  });
}

function registerHttp2SessionLifecycle(
  session: ClientHttp2Session,
  key: string
) {
  const teardown = () => {
    if (http2Sessions.get(key) === session) {
      http2Sessions.delete(key);
    }
  };
  session.once("close", teardown);
  session.once("error", teardown);
  session.once("goaway", teardown);
}

function deriveRoute(url: string): ProxyRoute | null {
  try {
    const parsed = new URL(url);
    const hostname = parsed.hostname.toLowerCase();
    const morphMatch = hostname.match(
      /^port-(\d+)-morphvm-([^.]+)\.http\.cloud\.morph\.so$/
    );
    if (morphMatch) {
      const morphId = morphMatch[2];
      if (morphId) {
        return {
          morphId,
          scope: "base",
          domainSuffix: "cmux.app",
        };
      }
    }
    for (const domain of CMUX_DOMAINS) {
      const suffix = `.${domain}`;
      if (!hostname.endsWith(suffix)) {
        continue;
      }
      const subdomain = hostname.slice(0, -suffix.length);
      if (!subdomain.startsWith("cmux-")) {
        continue;
      }
      const remainder = subdomain.slice("cmux-".length);
      const segments = remainder
        .split("-")
        .filter((segment) => segment.length > 0);
      if (segments.length < 3) {
        continue;
      }
      const portSegment = segments.pop();
      const scopeSegment = segments.pop();
      if (!portSegment || !scopeSegment) {
        continue;
      }
      if (!/^\d+$/.test(portSegment)) {
        continue;
      }
      const morphId = segments.join("-");
      if (!morphId) {
        continue;
      }
      return {
        morphId,
        scope: scopeSegment,
        domainSuffix: domain,
      };
    }
  } catch (error) {
    console.error("Failed to derive route", error);
    return null;
  }
  return null;
}
