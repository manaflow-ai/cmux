
import http, {
  type IncomingHttpHeaders,
  type IncomingMessage,
  type ServerResponse,
} from "node:http";
import https from "node:https";
import http2 from "node:http2";
import net, { type Socket } from "node:net";
import tls, { type TLSSocket } from "node:tls";
import { randomBytes, createHash } from "node:crypto";
import { pipeline as streamPipeline } from "node:stream/promises";
import { URL } from "node:url";
import type { Session, WebContents } from "electron";
import { isLoopbackHostname } from "@cmux/shared";
import { CertificateManager } from "./preview-proxy-certs";
import type { Logger } from "./chrome-camouflage";

type ProxyServer = http.Server;
type ClientHttp2Session = http2.ClientHttp2Session;
type ClientHttp2Stream = http2.ClientHttp2Stream;

const CMUX_PROXY_PORT = 39379;
const DEFAULT_MORPH_DOMAIN_SUFFIX = ".http.cloud.morph.so";
const HTTP2_CANCEL_CODE = http2.constants.NGHTTP2_CANCEL;
const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "proxy-connection",
  "te",
  "trailers",
  "transfer-encoding",
  "upgrade",
]);

const TASK_RUN_PREVIEW_PREFIX = "task-run-preview:";

function envFlagEnabled(
  value: string | undefined,
  defaultValue: boolean
): boolean {
  if (value === undefined) {
    return defaultValue;
  }
  const normalized = value.trim().toLowerCase();
  if (normalized === "") {
    return true;
  }
  if (
    normalized === "1" ||
    normalized === "true" ||
    normalized === "yes" ||
    normalized === "on"
  ) {
    return true;
  }
  if (
    normalized === "0" ||
    normalized === "false" ||
    normalized === "no" ||
    normalized === "off"
  ) {
    return false;
  }
  return defaultValue;
}

const DEFAULT_PROXY_LOGGING_ENABLED = envFlagEnabled(
  process.env.CMUX_PREVIEW_PROXY_LOG ?? process.env.CMUX_PREVIEW_PROXY_LOGGING,
  false
);
const CMUX_DOMAINS = [
  "cmux.app",
  "cmux.sh",
  "cmux.dev",
  "cmux.local",
  "cmux.localhost",
  "autobuild.app",
] as const;

const HTTP1_KEEP_ALIVE_AGENT = new http.Agent({
  keepAlive: true,
  keepAliveMsecs: 10_000,
  maxSockets: 256,
  maxFreeSockets: 64,
});

const HTTPS1_KEEP_ALIVE_AGENT = new https.Agent({
  keepAlive: true,
  keepAliveMsecs: 10_000,
  maxSockets: 256,
  maxFreeSockets: 64,
});

const ENABLE_TLS_MITM =
  process.env.CMUX_PREVIEW_TLS_MITM === undefined ||
  process.env.CMUX_PREVIEW_TLS_MITM === "" ||
  process.env.CMUX_PREVIEW_TLS_MITM === "1";

interface ProxyRoute {
  morphId: string;
  scope: string;
  domainSuffix: (typeof CMUX_DOMAINS)[number];
  cmuxProxyOrigin?: string;
}

interface ProxyContext {
  username: string;
  password: string;
  authToken: string;
  route: ProxyRoute | null;
  session: Session;
  webContentsId: number;
  persistKey?: string;
}

interface CmuxProxyMetadata {
  hostOverride: string;
  upstreamPort: number;
}

interface ProxyTarget {
  url: URL;
  secure: boolean;
  connectPort: number;
  cmuxProxy?: CmuxProxyMetadata;
}

interface ConnectTunnelOptions {
  clientResponseAlreadySent?: boolean;
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
const http2Sessions = new Map<string, ClientHttp2Session>();
const pendingHttp2Sessions = new Map<string, Promise<ClientHttp2Session>>();
const certificateManager = new CertificateManager();

export function setPreviewProxyLoggingEnabled(enabled: boolean): void {
  proxyLoggingEnabled = Boolean(enabled);
}

const contextsByUsername = new Map<string, ProxyContext>();
const contextsByWebContentsId = new Map<number, ProxyContext>();
const contextsByAuthToken = new Map<string, ProxyContext>();
const SOCKET_CONTEXT_SYMBOL = Symbol("cmuxPreviewProxyContext");

type ContextAwareSocket = (Socket | TLSSocket) & {
  [SOCKET_CONTEXT_SYMBOL]?: ProxyContext;
};

function attachContextToSocket(
  socket: Socket | TLSSocket,
  context: ProxyContext
): void {
  (socket as ContextAwareSocket)[SOCKET_CONTEXT_SYMBOL] = context;
}

function getContextForSocket(
  socket: Socket | TLSSocket | undefined
): ProxyContext | null {
  if (!socket) {
    return null;
  }
  const stored = (socket as ContextAwareSocket)[SOCKET_CONTEXT_SYMBOL];
  return stored ?? null;
}

function logPreviewProxyToConsole(
  level: "log" | "warn",
  event: string,
  data?: Record<string, unknown>
): void {
  const prefix = `[cmux-preview-proxy] ${event}`;
  if (data && Object.keys(data).length > 0) {
    console[level](prefix, data);
  } else {
    console[level](prefix);
  }
}

function proxyLog(event: string, data?: Record<string, unknown>): void {
  if (!proxyLoggingEnabled) {
    return;
  }
  try {
    proxyLogger?.log("Preview proxy", { event, ...(data ?? {}) });
    logPreviewProxyToConsole("log", event, data);
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
    logPreviewProxyToConsole("warn", event, data);
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
  contextsByAuthToken.delete(context.authToken);
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
  proxyLog("session-proxy-setup-called", {
    webContentsId: webContents.id,
    initialUrl,
    persistKey,
  });
  const route = deriveRoute(initialUrl);
  if (!route) {
    logger.warn("Preview proxy skipped; unable to parse cmux host", {
      url: initialUrl,
      persistKey,
    });
    proxyLog("session-proxy-skipped", {
      webContentsId: webContents.id,
      persistKey,
      reason: "no-route",
      initialUrl,
    });
    return () => {};
  }

  const port = await ensureProxyServer(logger);
  const username = `wc-${webContents.id}-${randomBytes(4).toString("hex")}`;
  const password = randomBytes(12).toString("hex");
  const authToken = Buffer.from(`${username}:${password}`).toString("base64");

  const context: ProxyContext = {
    username,
    password,
    authToken,
    route,
    session: webContents.session,
    webContentsId: webContents.id,
    persistKey,
  };

  contextsByUsername.set(username, context);
  contextsByWebContentsId.set(webContents.id, context);
  contextsByAuthToken.set(authToken, context);

  try {
    await webContents.session.setProxy({
      mode: "fixed_servers",
      proxyRules: `http=127.0.0.1:${port};https=127.0.0.1:${port}`,
      proxyBypassRules: "<-loopback>",
    });
    proxyLog("session-proxy-configured", {
      webContentsId: webContents.id,
      persistKey,
      route,
      port,
    });
  } catch (error) {
    contextsByUsername.delete(username);
    contextsByWebContentsId.delete(webContents.id);
    contextsByAuthToken.delete(authToken);
    logger.warn("Failed to configure preview proxy", { error });
    proxyWarn("session-proxy-error", {
      webContentsId: webContents.id,
      persistKey,
      error,
    });
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
    const server = http.createServer();
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

  server.on("request", handleHttpRequest);
  server.on("request", (req) => {
    proxyLog("raw-http-request", {
      method: req.method,
      url: req.url,
      host: req.headers.host,
    });
  });
  server.on("connect", handleConnect);
  server.on("upgrade", handleUpgrade);
  server.on("clientError", (error, socket) => {
    proxyLogger?.warn("Proxy client error", { error });
    socket.end();
  });
}

async function getHttp2SessionFor(
  target: ProxyTarget
): Promise<ClientHttp2Session> {
  const originKey = target.url.origin;
  const existing = http2Sessions.get(originKey);
  if (existing && !existing.closed && !existing.destroyed) {
    return existing;
  }
  const pending = pendingHttp2Sessions.get(originKey);
  if (pending) {
    return pending;
  }

  const creating = createHttp2Session(target.url);
  pendingHttp2Sessions.set(originKey, creating);
  try {
    const session = await creating;
    http2Sessions.set(originKey, session);
    monitorHttp2Session(originKey, session);
    return session;
  } finally {
    pendingHttp2Sessions.delete(originKey);
  }
}

function createHttp2Session(url: URL): Promise<ClientHttp2Session> {
  return new Promise((resolve, reject) => {
    const options: http2.SecureClientSessionOptions = {};
    if (process.env.TEST_ALLOW_INSECURE_UPSTREAM === "true") {
        options.rejectUnauthorized = false;
    }
    const session = http2.connect(url.origin, options);
    let settled = false;

    const handleConnect = () => {
      if (settled) {
        return;
      }
      settled = true;
      session.removeListener("error", handleError);
      resolve(session);
    };

    const handleError = (error: Error) => {
      if (settled) {
        proxyLogger?.warn("HTTP/2 session error", {
          origin: url.origin,
          error,
        });
        return;
      }
      settled = true;
      session.removeListener("connect", handleConnect);
      session.destroy();
      reject(error);
    };

    session.once("connect", handleConnect);
    session.once("error", handleError);
  });
}

function monitorHttp2Session(originKey: string, session: ClientHttp2Session) {
  const handleTeardown = () => {
    const existing = http2Sessions.get(originKey);
    if (existing === session) {
      http2Sessions.delete(originKey);
    }
  };

  session.on("close", handleTeardown);
  session.on("goaway", () => {
    handleTeardown();
    if (!session.closed && !session.destroyed) {
      session.close();
    }
  });
  session.on("error", (error) => {
    proxyLogger?.warn("HTTP/2 session runtime error", {
      origin: originKey,
      error,
    });
    handleTeardown();
  });
}

function handleHttpRequest(req: IncomingMessage, res: ServerResponse) {

  const context = authenticateRequest(req.headers, req.socket);
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
  void forwardHttpRequest(req, res, rewritten, context).catch((error) => {
    proxyWarn("http-forward-error", {
      error,
      persistKey: context.persistKey,
    });
    if (!res.headersSent) {
      res.writeHead(502);
    }
    res.end("Bad Gateway");
  });
}

function handleConnect(
  req: IncomingMessage,
  socket: Socket,
  head: Buffer
) {

  const context = authenticateRequest(req.headers, socket);
  if (!context) {

    socket.write(
      'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="Cmux Preview Proxy"\r\n\r\n'
    );
    socket.end();
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

  const tlsCandidate = shouldInterceptTls(target.hostname, context, head);
  proxyLog("connect-classify", {
    username: context.username,
    requestedHost: target.hostname,
    requestedPort: target.port,
    route: context.route
      ? `${context.route.morphId}:${context.route.scope}`
      : null,
    headLength: head.length,
    headSample: head.length > 0 ? head.subarray(0, 8).toString("hex") : "",
    tlsCandidate,
  });

  if (tlsCandidate) {
    proxyLog("connect-mitm", {
      username: context.username,
      requestedHost: target.hostname,
      requestedPort: target.port,
      rewrittenHost: rewritten.url.hostname,
      rewrittenPort: rewritten.connectPort,
      persistKey: context.persistKey,
    });
    establishMitmTunnel(
      socket,
      head,
      target.hostname,
      target.port,
      context,
      rewritten
    );
    return;
  }

  proxyLog("connect-request", {
    username: context.username,
    requestedHost: target.hostname,
    requestedPort: target.port,
    rewrittenHost: rewritten.url.hostname,
    rewrittenPort: rewritten.connectPort,
    persistKey: context.persistKey,
  });
  forwardConnectTunnel(socket, head, rewritten);
}

function shouldInterceptTls(
  hostname: string,
  context: ProxyContext,
  _head: Buffer
): boolean {
  if (!ENABLE_TLS_MITM) {
    return false;
  }
  if (!context.route) {
    return false;
  }
  if (isLoopbackHostname(hostname) || hostname.endsWith(".cmux.local")) {
    return true;
  }
  return false;
}

function looksLikeTlsHandshake(data: Buffer): boolean {
  const first = data[0];
  const versionMajor = data[1];
  if (first !== 0x16) {
    return false;
  }
  if (versionMajor !== 0x03) {
    return false;
  }
  return true;
}

type MitmInitialClassification =
  | { kind: "need-more" }
  | { kind: "plain" }
  | { kind: "tls"; alpnProtocols?: string[] };

function classifyMitmInitialBytes(buffer: Buffer): MitmInitialClassification {
  if (buffer.length < 3) {
    return { kind: "need-more" };
  }
  if (!looksLikeTlsHandshake(buffer)) {
    return { kind: "plain" };
  }
  const clientHello = parseClientHello(buffer);
  if (!clientHello) {
    return { kind: "need-more" };
  }
  if (!clientHello.isTls) {
    return { kind: "plain" };
  }
  return { kind: "tls", alpnProtocols: clientHello.alpnProtocols };
}

interface ClientHelloInfo {
  isTls: boolean;
  alpnProtocols?: string[];
}

function parseClientHello(buffer: Buffer): ClientHelloInfo | null {
  if (buffer.length < 5) {
    return null;
  }
  if (buffer[0] !== 0x16) {
    return { isTls: false };
  }
  const recordLength = buffer.readUInt16BE(3);
  if (buffer.length < 5 + recordLength) {
    return null;
  }
  if (buffer.length < 9) {
    return null;
  }
  const handshakeType = buffer[5];
  if (handshakeType !== 0x01) {
    return { isTls: true };
  }
  const handshakeLength = buffer.readUIntBE(6, 3);
  const handshakeEnd = 9 + handshakeLength;
  if (buffer.length < handshakeEnd) {
    return null;
  }
  const clientHello = buffer.subarray(9, handshakeEnd);
  if (clientHello.length < 34) {
    return null;
  }
  let offset = 0;
  offset += 2; // legacy_version
  offset += 32; // random
  if (offset >= clientHello.length) {
    return null;
  }
  const sessionIdLength = clientHello[offset] ?? 0;
  offset += 1;
  if (offset + sessionIdLength > clientHello.length) {
    return null;
  }
  offset += sessionIdLength;
  if (offset + 2 > clientHello.length) {
    return null;
  }
  const cipherSuitesLength = clientHello.readUInt16BE(offset);
  offset += 2;
  if (offset + cipherSuitesLength > clientHello.length) {
    return null;
  }
  offset += cipherSuitesLength;
  if (offset >= clientHello.length) {
    return null;
  }
  const compressionMethodsLength = clientHello[offset] ?? 0;
  offset += 1;
  if (offset + compressionMethodsLength > clientHello.length) {
    return null;
  }
  offset += compressionMethodsLength;
  if (offset + 2 > clientHello.length) {
    return null;
  }
  const extensionsLength = clientHello.readUInt16BE(offset);
  offset += 2;
  if (offset + extensionsLength > clientHello.length) {
    return null;
  }
  const extensionsEnd = offset + extensionsLength;
  const alpnProtocols: string[] = [];
  let foundAlpn = false;
  while (offset + 4 <= extensionsEnd) {
    const extensionType = clientHello.readUInt16BE(offset);
    offset += 2;
    const extensionSize = clientHello.readUInt16BE(offset);
    offset += 2;
    if (offset + extensionSize > extensionsEnd) {
      return null;
    }
    if (extensionType === 0x0010 && extensionSize >= 2) {
      const listLength = clientHello.readUInt16BE(offset);
      let cursor = offset + 2;
      const listEnd = cursor + listLength;
      if (listEnd > offset + extensionSize) {
        return null;
      }
      while (cursor < listEnd) {
        const nameLength = clientHello[cursor];
        cursor += 1;
        if (!nameLength || cursor + nameLength > listEnd) {
          break;
        }
        const protocol = clientHello
          .subarray(cursor, cursor + nameLength)
          .toString("utf8");
        alpnProtocols.push(protocol);
        cursor += nameLength;
      }
      foundAlpn = alpnProtocols.length > 0;
    }
    offset += extensionSize;
  }
  return {
    isTls: true,
    alpnProtocols: foundAlpn ? alpnProtocols : undefined,
  };
}


function containsHttp3Protocol(protocols: string[] | undefined): boolean {
  if (!protocols || protocols.length === 0) {
    return false;
  }
  return protocols.some((protocol) => {
    if (!protocol) return false;
    const normalized = protocol.toLowerCase();
    return normalized === "h3" || normalized.startsWith("h3-");
  });
}

function handleUpgrade(req: IncomingMessage, socket: Socket, head: Buffer) {

  const context = authenticateRequest(req.headers, req.socket);
  if (!context) {
    respondProxyAuthRequiredSocket(socket);
    proxyWarn("upgrade-auth-required", {
      url: req.url,
      host: req.headers.host,
    });
    return;
  }
  
  socket.resume();

  proxyLog("upgrade-request", {
    username: context.username,
    url: req.url,
    host: req.headers.host,
    upgrade: req.headers.upgrade,
    origin: req.headers.origin,
  });

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
  headers: IncomingHttpHeaders,
  socket?: Socket | TLSSocket
): ProxyContext | null {
  const token = extractBasicToken(headers["proxy-authorization"]);
  if (!token) {
    const socketContext = getContextForSocket(socket);
    if (socketContext) {
      return socketContext;
    }

    return null;
  }
  const cached = contextsByAuthToken.get(token);
  if (cached) {
    return cached;
  }

  // Fallback: decode to locate username map entry in case the cache missed an update.
  try {
    const decoded = Buffer.from(token, "base64").toString("utf8");
    const separatorIndex = decoded.indexOf(":");
    if (separatorIndex === -1) return null;
    const username = decoded.slice(0, separatorIndex);
    const password = decoded.slice(separatorIndex + 1);
    const context = contextsByUsername.get(username);
    if (!context || context.password !== password) {

      return null;
    }
    return context;
  } catch (_err) {

    return null;
  }
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

function extractBasicToken(raw: string | string[] | undefined): string | null {
  let value: string;
  if (Array.isArray(raw)) {
    value = raw[0];
  } else if (typeof raw === "string") {
    value = raw;
  } else {
    return null;
  }
  
  const trimmed = value.trim();
  if (!trimmed) {
    return null;
  }
  const spaceIndex = trimmed.indexOf(" ");
  if (spaceIndex === -1) {
    return null;
  }
  const scheme = trimmed.slice(0, spaceIndex).toLowerCase();
  if (scheme !== "basic") {
    return null;
  }
  const token = trimmed.slice(spaceIndex + 1).trim();
  return token || null;
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
  const requestedPort = determineRequestedPort(url);
  // Allow rewriting if loopback OR if we are in test mode with a specific origin
  if (context.route && (isLoopbackHostname(url.hostname) || process.env.TEST_CMUX_PROXY_ORIGIN)) {
    const proxyTarget = buildCmuxProxyTarget(url, requestedPort, context.route);
    if (proxyTarget) {
      return proxyTarget;
    }
    const rewritten = new URL(url.toString());
    rewritten.protocol = "https:";
    rewritten.hostname = buildCmuxHost(context.route, requestedPort);
    rewritten.port = "";
    return {
      url: rewritten,
      secure: true,
      connectPort: 443,
    };
  }

  const rewritten = new URL(url.toString());
  const secure = rewritten.protocol === "https:";
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

function buildCmuxProxyTarget(
  original: URL,
  requestedPort: number,
  route: ProxyRoute
): ProxyTarget | null {
  if (!route.cmuxProxyOrigin) {
    return null;
  }
  try {
    const rewritten = new URL(route.cmuxProxyOrigin);
    rewritten.pathname = original.pathname;
    rewritten.search = original.search;
    rewritten.hash = "";
    const connectPort = Number.parseInt(rewritten.port, 10);
    const resolvedPort = Number.isNaN(connectPort)
      ? rewritten.protocol === "https:"
        ? 443
        : 80
      : connectPort;
    const hostOverride = formatHostOverride(original.hostname, requestedPort);
    return {
      url: rewritten,
      secure: rewritten.protocol === "https:",
      connectPort: resolvedPort,
      cmuxProxy: {
        hostOverride,
        upstreamPort: requestedPort,
      },
    };
  } catch (error) {
    console.error("Failed to build cmux proxy target", error);
    return null;
  }
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

function formatHostOverride(hostname: string, port: number): string {
  if (hostname.includes(":")) {
    if (hostname.startsWith("[") && hostname.endsWith("]")) {
      return `${hostname}:${port}`;
    }
    return `[${hostname}]:${port}`;
  }
  return `${hostname}:${port}`;
}

function buildCmuxHost(route: ProxyRoute, port: number): string {
  const safePort = Number.isFinite(port) && port > 0 ? Math.floor(port) : 80;
  return `cmux-${route.morphId}-${route.scope}-${safePort}.${route.domainSuffix}`;
}

function shouldAttemptHttp2(target: ProxyTarget): boolean {
  if (!target.secure) {
    return false;
  }
  if (process.env.TEST_CMUX_PROXY_ORIGIN) {
      return true;
  }
  if (target.cmuxProxy) {
    return true;
  }
  const hostname = target.url.hostname.toLowerCase();
  return hostname.endsWith(DEFAULT_MORPH_DOMAIN_SUFFIX);
}

async function forwardHttpRequest(
  clientReq: IncomingMessage,
  clientRes: ServerResponse,
  target: ProxyTarget,
  context: ProxyContext
): Promise<void> {
  if (shouldAttemptHttp2(target)) {
    try {
      await forwardHttpRequestViaHttp2(clientReq, clientRes, target, context);
      return;
    } catch (error) {
      proxyWarn("http2-forward-failed", {
        error,
        persistKey: context.persistKey,
        username: context.username,
        host: target.url.hostname,
      });
      if (clientRes.writableEnded) {
        return;
      }
    }
  }
  await forwardHttpRequestViaHttp1(clientReq, clientRes, target, context);
}

function forwardHttpRequestViaHttp1(
  clientReq: IncomingMessage,
  clientRes: ServerResponse,
  target: ProxyTarget,
  context: ProxyContext
): Promise<void> {
  return new Promise((resolve) => {
    const { url, secure, connectPort } = target;
    const requestHeaders = buildHttp1Headers(clientReq.headers, target);
    const agent = secure ? HTTPS1_KEEP_ALIVE_AGENT : HTTP1_KEEP_ALIVE_AGENT;

    const requestOptions = {
      protocol: secure ? "https:" : "http:",
      hostname: url.hostname,
      port: connectPort,
      method: clientReq.method,
      path: url.pathname + url.search,
      headers: requestHeaders.headers,
      setHost: requestHeaders.setHost,
      agent,
    };

    const httpModule = secure ? https : http;
    const proxyReq = httpModule.request(requestOptions, (proxyRes) => {
      if (!clientRes.headersSent) {
        clientRes.writeHead(
          proxyRes.statusCode ?? 500,
          proxyRes.statusMessage ?? "",
          proxyRes.headers
        );
      }
      void streamPipeline(proxyRes, clientRes)
        .then(() => {
          resolve();
        })
        .catch((pipelineError) => {
          proxyWarn("http1-response-pipeline-error", {
            error: pipelineError,
            host: url.hostname,
          });
          if (!clientRes.headersSent) {
            clientRes.writeHead(502);
            clientRes.end("Bad Gateway");
          } else if (!clientRes.writableEnded) {
            clientRes.end();
          }
          resolve();
        });
    });

    proxyReq.on("error", (error) => {
      proxyWarn("http-upstream-error", {
        error,
        persistKey: context.persistKey,
        username: context.username,
        host: url.hostname,
      });
      if (!clientRes.headersSent) {
        clientRes.writeHead(502);
      }
      clientRes.end("Bad Gateway");
      resolve();
    });

    clientReq.pipe(proxyReq);
    clientReq.on("aborted", () => {
      proxyReq.destroy();
      resolve();
    });
  });
}

async function forwardHttpRequestViaHttp2(
  clientReq: IncomingMessage,
  clientRes: ServerResponse,
  target: ProxyTarget,
  context: ProxyContext
): Promise<void> {
  const session = await getHttp2SessionFor(target);
  const headers = buildHttp2Headers(clientReq.headers, target);
  headers[":method"] = clientReq.method ?? "GET";
  headers[":path"] = `${target.url.pathname}${target.url.search}`;
  headers[":scheme"] = target.url.protocol.replace(":", "");
  headers[":authority"] = target.url.host;

  await new Promise<void>((resolve, reject) => {
    const upstreamReq: ClientHttp2Stream = session.request(headers);
    const logHttp2 = (event: string, data?: Record<string, unknown>) => {
      proxyLog("http2-forward", {
        event,
        targetHost: target.url.hostname,
        targetPort: target.connectPort,
        persistKey: context.persistKey,
        username: context.username,
        streamId: upstreamReq.id,
        ...(data ?? {}),
      });
    };

    logHttp2("request-start", {
      method: headers[":method"],
      path: headers[":path"],
    });

    upstreamReq.on("response", (upstreamHeaders) => {
      const status = Number(upstreamHeaders[":status"] ?? 502);
      const responseHeaders: Record<string, string | string[]> = {};
      for (const [name, value] of Object.entries(upstreamHeaders)) {
        if (name.startsWith(":")) continue;
        if (Array.isArray(value)) {
          responseHeaders[name] = value.map((entry) => entry?.toString() ?? "");
        } else if (typeof value === "string") {
          responseHeaders[name] = value;
        } else if (typeof value === "number") {
          responseHeaders[name] = String(value);
        }
      }
      if (!clientRes.headersSent) {
        clientRes.writeHead(status, responseHeaders);
      }
      logHttp2("response-headers", {
        status,
        headerCount: Object.keys(responseHeaders).length,
      });
    });

    upstreamReq.on("data", (chunk) => {
      if (!clientRes.writableEnded) {
        clientRes.write(chunk);
      }
    });

    upstreamReq.on("end", () => {
      if (!clientRes.writableEnded) {
        clientRes.end();
      }
      logHttp2("response-end");
      resolve();
    });

    upstreamReq.on("error", (error) => {
      logHttp2("stream-error", {
        message: (error as Error).message,
      });
      if (!clientRes.headersSent) {
        clientRes.writeHead(502);
        clientRes.end("Bad Gateway");
      } else if (!clientRes.writableEnded) {
        clientRes.end();
      }
      upstreamReq.close(HTTP2_CANCEL_CODE);
      reject(error);
    });

    clientReq.pipe(upstreamReq);
    clientReq.on("aborted", () => {
      logHttp2("client-aborted");
      upstreamReq.close(HTTP2_CANCEL_CODE);
    });
  });
}

function buildHttp2Headers(
  source: IncomingHttpHeaders,
  target: ProxyTarget
): http2.OutgoingHttpHeaders {
  const headers: Record<string, string> = {};
  for (const [key, value] of Object.entries(source)) {
    if (!value) continue;
    const lowerKey = key.toLowerCase();
    if (lowerKey === "proxy-authorization") continue;
    if (lowerKey === "host" && target.cmuxProxy) continue;
    if (HOP_BY_HOP_HEADERS.has(lowerKey)) continue;
    if (Array.isArray(value)) {
      headers[lowerKey] = value.join(", ");
    } else {
      headers[lowerKey] = value;
    }
  }
  if (!target.cmuxProxy) {
    headers.host = target.url.host;
  }
  injectCmuxProxyHeaders(headers, target.cmuxProxy);
  return headers;
}

function buildHttp1Headers(
  source: IncomingHttpHeaders,
  target: ProxyTarget
): { headers: Record<string, string>; setHost?: boolean } {
  const headers: Record<string, string> = {};
  for (const [key, value] of Object.entries(source)) {
    if (!value) continue;
    const lowerKey = key.toLowerCase();
    if (lowerKey === "proxy-authorization") continue;
    if (lowerKey === "host" && target.cmuxProxy) continue;
    if (Array.isArray(value)) {
      headers[lowerKey] = value.join(", ");
    } else {
      headers[lowerKey] = value;
    }
  }
  if (!target.cmuxProxy) {
    headers.host = target.url.host;
  }
  injectCmuxProxyHeaders(headers, target.cmuxProxy);
  return { headers, setHost: target.cmuxProxy ? false : undefined };
}

function normalizeHeaderName(name: string): string {
  if (/^[A-Z0-9-]+$/.test(name)) {
    return name;
  }
  return name.replace(
    /(^|-)([a-z])/g,
    (_match, prefix, char) => `${prefix}${char.toUpperCase()}`
  );
}

function deleteHeaderCaseInsensitive(
  headers: Record<string, string>,
  targetName: string
): void {
  const lower = targetName.toLowerCase();
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === lower) {
      delete headers[key];
    }
  }
}

function setHeader(
  headers: Record<string, string>,
  name: string,
  value: string
): void {
  const normalized = normalizeHeaderName(name);
  deleteHeaderCaseInsensitive(headers, normalized);
  headers[normalized] = value;
}

function injectCmuxProxyHeaders(
  headers: Record<string, string>,
  metadata: CmuxProxyMetadata | undefined
) {
  deleteHeaderCaseInsensitive(headers, "X-Cmux-Port-Internal");
  deleteHeaderCaseInsensitive(headers, "X-Cmux-Host-Override");
  if (!metadata) {
    return;
  }
  setHeader(headers, "X-Cmux-Port-Internal", String(metadata.upstreamPort));
  setHeader(headers, "X-Cmux-Host-Override", metadata.hostOverride);
}

function forwardUpgradeRequest(
  clientReq: IncomingMessage,
  socket: Socket,
  head: Buffer,
  target: ProxyTarget
) {
  const { url } = target;
  const upstream = createUpstreamSocket(target);
  const logForward = (event: string, data?: Record<string, unknown>) => {
    proxyLog("upgrade-forward", {
      event,
      targetHost: url.hostname,
      targetPort: target.connectPort,
      ...(data ?? {}),
    });
  };

  const handleConnected = () => {
    logForward("upstream-connected", {
      targetHost: url.hostname,
      targetPort: target.connectPort,
      secure: target.secure,
      cmuxProxy: !!target.cmuxProxy,
      localPort: socket.localPort,
      remotePort: socket.remotePort
    });
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries(clientReq.headers)) {
      if (!value) continue;
      const lowerKey = key.toLowerCase();
      if (lowerKey === "proxy-authorization") continue;
      if (lowerKey === "host" && target.cmuxProxy) continue;
      headers[lowerKey] = Array.isArray(value) ? value.join(", ") : value;
    }
    // Cloud Run expects a Host header during WebSocket upgrades even when we route via cmux proxy headers.
    headers.host = url.host;
    injectCmuxProxyHeaders(headers, target.cmuxProxy);

    logForward("request-headers", {
      headers,
    });

    const lines = [
      `${clientReq.method ?? "GET"} ${url.pathname}${url.search} HTTP/1.1`,
    ];
    for (const [key, value] of Object.entries(headers)) {
      lines.push(`${key}: ${value}`);
    }
    lines.push("\r\n");
    upstream.write(lines.join("\r\n"));
    logForward("request-forwarded", {
      method: clientReq.method,
      path: `${url.pathname}${url.search}`,
      headerCount: Object.keys(headers).length,
    });
    if (head.length > 0) {
      upstream.write(head);
    }

    /*
    upstream.on('data', (chunk) => {
        logForward("upstream-data", { length: chunk.length });
    });
    
    upstream.on('end', () => {
        logForward("upstream-end");
    });
    
    upstream.on('close', () => {
        logForward("upstream-close");
    });
    
    upstream.on('error', (err) => {
        logForward("upstream-error", { error: err.message });
    });

    socket.on('drain', () => {
        logForward("socket-drain");
    });
    
    socket.on('error', (err) => {
        logForward("socket-error", { error: err.message });
    });
    
    socket.on('close', () => {
        logForward("socket-close");
    });
    */

    upstream.pipe(socket);
    socket.pipe(upstream);
    logForward("pipes-established");
  };

  if (target.secure && upstream instanceof tls.TLSSocket) {
    upstream.once("secureConnect", handleConnected);
  } else {
    upstream.once("connect", handleConnected);
  }

  upstream.on("error", (error) => {
    proxyWarn("upgrade-upstream-error", {
      error,
      host: url.hostname,
      port: target.connectPort,
    });
    logForward("upstream-error", { message: (error as Error).message });
    socket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
    socket.end();
  });

  upstream.on("close", () => {
    logForward("upstream-closed");
  });

  socket.on("error", (error) => {
    logForward("client-error", { message: (error as Error).message });
    upstream.destroy();
  });

  socket.on("close", () => {
    logForward("client-closed");
  });
}

function createUpstreamSocket(target: ProxyTarget): Socket | TLSSocket {
  if (target.secure) {
    return tls.connect({
      host: target.url.hostname,
      port: target.connectPort,
      servername: target.url.hostname,
    });
  }
  return net.connect(target.connectPort, target.url.hostname);
}

function establishDirectConnect(
  clientSocket: Socket,
  head: Buffer,
  target: ProxyTarget,
  options?: ConnectTunnelOptions
) {
  const upstream = net.connect(target.connectPort, target.url.hostname, () => {
    if (!options?.clientResponseAlreadySent) {
      clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    }
    if (head.length > 0) {
      upstream.write(head);
    }
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });

  upstream.on("error", (error) => {
    proxyLogger?.warn("CONNECT upstream error", { error });
    if (!options?.clientResponseAlreadySent) {
      clientSocket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
    }
    clientSocket.end();
  });

  clientSocket.on("error", () => {
    upstream.destroy();
  });
}

function establishCmuxProxyConnect(
  clientSocket: Socket,
  head: Buffer,
  target: ProxyTarget,
  options?: ConnectTunnelOptions
) {
  const upstream = createUpstreamSocket(target);
  const sendConnectRequest = () => {
    const headers: Record<string, string> = {};
    injectCmuxProxyHeaders(headers, target.cmuxProxy);
    const lines = [`CONNECT ${target.url.host} HTTP/1.1`];
    for (const [key, value] of Object.entries(headers)) {
      lines.push(`${key}: ${value}`);
    }
    lines.push("\r\n");
    upstream.write(lines.join("\r\n"));
  };

  const onError = (error: Error) => {
    proxyLogger?.warn("CONNECT cmux upstream error", { error });
    if (!options?.clientResponseAlreadySent) {
      clientSocket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
    }
    clientSocket.end();
    upstream.destroy();
  };

  const chunks: Buffer[] = [];
  const handleData = (chunk: Buffer) => {
    chunks.push(chunk);
    const combined = Buffer.concat(chunks);
    const headerEnd = combined.indexOf("\r\n\r\n");
    if (headerEnd === -1) {
      return;
    }
    upstream.removeListener("data", handleData);
    const headerText = combined.slice(0, headerEnd).toString("utf8");
    if (!/^HTTP\/1\.1 200/.test(headerText)) {
      upstream.removeListener("data", handleData);
      if (!options?.clientResponseAlreadySent) {
        clientSocket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
      }
      clientSocket.end();
      upstream.destroy();
      return;
    }
    if (!options?.clientResponseAlreadySent) {
      clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    }
    const remaining = combined.slice(headerEnd + 4);
    if (remaining.length > 0) {
      clientSocket.write(remaining);
    }
    if (head.length > 0) {
      upstream.write(head);
    }
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  };

  upstream.on("data", handleData);
  upstream.on("error", onError);
  clientSocket.on("error", () => {
    upstream.destroy();
  });

  if (target.secure && upstream instanceof tls.TLSSocket) {
    upstream.once("secureConnect", sendConnectRequest);
  } else {
    upstream.once("connect", sendConnectRequest);
  }
}

function forwardConnectTunnel(
  clientSocket: Socket,
  head: Buffer,
  target: ProxyTarget,
  options?: ConnectTunnelOptions
) {
  if (target.cmuxProxy) {
    establishCmuxProxyConnect(clientSocket, head, target, options);
    return;
  }
  establishDirectConnect(clientSocket, head, target, options);
}

function establishMitmTunnel(
  clientSocket: Socket,
  head: Buffer,
  originalHostname: string,
  _originalPort: number,
  context: ProxyContext,
  target: ProxyTarget
) {
  if (!proxyServer) {
    clientSocket.write("HTTP/1.1 500 Internal Server Error\r\n\r\n");
    clientSocket.end();
    return;
  }
  const server = proxyServer;

  let buffered = head;
  let settled = false;

  function onData(chunk: Buffer) {
      handleData(chunk);
  }

  function cleanup() {
    settled = true;
    // Remove specific listener
    clientSocket.removeListener("data", onData);
    clientSocket.removeListener("error", handleClientError);
    clientSocket.removeListener("close", handleClientClose);
    // Pause to prevent further data events from unshift until TLS socket takes over
    clientSocket.pause();
  }

  function handleTlsTunnel(initial: Buffer) {
    const hostname = originalHostname;
    const { key, cert } = certificateManager.getCertDataForHost(hostname);
    
    if (!key || !cert) {
        proxyLog("mitm-cert-error", { error: "Missing key or cert", hostname });
        clientSocket.destroy();
        return;
    }

    const tlsServer = tls.createServer({
        key,
        cert,
        ALPNProtocols: ["h2", "http/1.1"],
    });

    tlsServer.on("secureConnection", (tlsSocket) => {
        // Close the server so it doesn't accept more connections (we only need one)
        tlsServer.close();

        attachContextToSocket(tlsSocket, context);

        tlsSocket.on("keylog", (line) => {
            proxyLog("mitm-tls-keylog", { line: line.toString() });
        });

        tlsSocket.on("clientError", (err) => {
            proxyLog("mitm-tls-client-error", { error: err });
        });
        const alpnProtocol = tlsSocket.alpnProtocol;
        proxyLog("mitm-tls-secure", {
            host: originalHostname,
            alpnProtocol,
        });
        
        if (alpnProtocol === "h2") {
            proxyLog("mitm-handling-h2", { host: originalHostname });
            handleHttp2Connection(tlsSocket, context, target);
        } else if (alpnProtocol === "http/1.1" || !alpnProtocol) {
            proxyLog("mitm-handling-plain", { host: originalHostname });
            
            // Synchronously read any buffered data
            const chunks: Buffer[] = [];
            let chunk;
            while (null !== (chunk = tlsSocket.read())) {
                chunks.push(chunk);
            }
            const initial = Buffer.concat(chunks);
            
            handlePlainTunnel(initial, tlsSocket);
            return;
        } else {
            proxyLog("mitm-handling-plain", { host: originalHostname });
            server.emit("connection", tlsSocket);
        }

        tlsSocket.on("error", (error) => {
          proxyLogger?.warn("MITM TLS error", {
            error,
            host: originalHostname,
          });
          tlsSocket.destroy();
        });
    });

    tlsServer.on("error", (err) => {
         proxyLog("mitm-tls-server-error", { error: err });
         clientSocket.destroy();
    });

    tlsServer.listen(0, "127.0.0.1", () => {
        const address = tlsServer.address();
        if (!address || typeof address === 'string') {
            proxyLog("mitm-tls-server-error", { error: "Invalid address" });
            clientSocket.destroy();
            return;
        }
        
        const proxySocket = net.connect(address.port, "127.0.0.1");
        
        proxySocket.on("connect", () => {
            if (initial.length > 0) {
                proxySocket.write(initial);
            }
            
            // Pipe data
            clientSocket.pipe(proxySocket);
            proxySocket.pipe(clientSocket);
            
            clientSocket.resume();
        });

        proxySocket.on("error", (err) => {
            proxyLog("mitm-proxy-socket-error", { error: err });
            clientSocket.destroy();
        });
        
        proxySocket.on("close", () => {
            tlsServer.close();
        });
    });
  }


  function handlePlainTunnel(initial: Buffer, socketOverride?: net.Socket) {
    const tunnelSocket = socketOverride || clientSocket;
    
    proxyLog("mitm-plain-tunnel", {
      host: originalHostname,
    });
    attachContextToSocket(tunnelSocket, context);
    
    // Internal HTTP server for non-upgrade requests
    const internalHttpServer = http.createServer((req, res) => {
      handleHttpRequest(req, res);
    });
    
    internalHttpServer.on('clientError', (err, socket) => {
        if (socket.writable) {
            socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
        }
    });

    internalHttpServer.on('connection', (socket) => {
        attachContextToSocket(socket, context);
    });

    // We need to listen to get a port
    internalHttpServer.listen(0, "127.0.0.1");
    
    const plainServer = net.createServer((socket) => {
        attachContextToSocket(socket, context);
        
        socket.once('data', (chunk) => {
            const str = chunk.toString();
            // Check for WebSocket upgrade
            if (str.includes("Upgrade: websocket") || str.includes("Upgrade: WebSocket")) {
                proxyLog("mitm-plain-manual-upgrade");
                
                // Parse minimal info for handleUpgrade
                const lines = str.split("\r\n");
                const requestLine = lines[0].split(" ");
                const method = requestLine[0];
                const url = requestLine[1];
                
                const headers: any = {};
                for (let i = 1; i < lines.length; i++) {
                    const line = lines[i];
                    if (line === "") break;
                    const parts = line.split(": ");
                    if (parts.length >= 2) {
                        headers[parts[0].toLowerCase()] = parts.slice(1).join(": ");
                    }
                }
                
                const mockReq: any = {
                    method,
                    url,
                    headers,
                    socket,
                    connection: socket
                };
                
                // The head is usually empty if the chunk contains just the headers
                // But if there is extra data, we should pass it.
                // For simplicity, we assume chunk contains headers and maybe body.
                // handleUpgrade expects 'head' to be the first packet of the upgraded stream.
                // It does NOT include the upgrade request headers.
                // The upgrade request headers are consumed by http.Server.
                
                // BUT, since we are bypassing http.Server, we need to send the upgrade request to the upstream!
                // forwardUpgradeRequest expects 'head' to be written to upstream.
                // So we should pass 'chunk' as 'head'?
                // NO. forwardUpgradeRequest is designed for when http.Server has already consumed the headers.
                // If we pass 'chunk' (the headers) as 'head', it will be written to upstream.
                // This is exactly what we want! The upstream needs the handshake request.
                
                // Wait, does forwardUpgradeRequest construct a new handshake request?
                // Let's check forwardUpgradeRequest.
                
                handleUpgrade(mockReq, socket, chunk);
            } else {
                // Not an upgrade, proxy to internal HTTP server
                const httpPort = (internalHttpServer.address() as net.AddressInfo).port;
                const httpSocket = net.connect(httpPort, "127.0.0.1");
                
                httpSocket.on('connect', () => {
                    httpSocket.write(chunk);
                    socket.pipe(httpSocket);
                    httpSocket.pipe(socket);
                });
                
                httpSocket.on('error', (err) => {
                    socket.destroy();
                });
                
                socket.on('error', () => {
                    httpSocket.destroy();
                });
            }
        });
    });

    plainServer.listen(0, "127.0.0.1", () => {
      const address = plainServer.address();
      if (!address || typeof address === "string") {
        tunnelSocket.destroy();
        return;
      }
      
      const proxySocket = net.connect(address.port, "127.0.0.1");
      
      proxySocket.on("connect", () => {
        if (initial.length > 0) {
            proxySocket.write(initial);
        }
        
        tunnelSocket.pipe(proxySocket);
        proxySocket.pipe(tunnelSocket);
        
        tunnelSocket.resume();
        proxySocket.resume();
      });
      
      proxySocket.on("error", () => {
        tunnelSocket.destroy();
      });
      
      proxySocket.on("close", () => {
        plainServer.close();
        internalHttpServer.close();
      });
    });
  }

  function classify() {
    const result = classifyMitmInitialBytes(buffered);
    proxyLog("mitm-classify-result", { kind: result.kind, bufferedLength: buffered.length });
    if (result.kind === "need-more") {
      return false;
    }
    cleanup();
    if (result.kind === "plain") {
      handlePlainTunnel(buffered);
      return true;
    }
    if (containsHttp3Protocol(result.alpnProtocols)) {
      proxyWarn("mitm-http3-detected", {
        host: originalHostname,
        alpnProtocols: result.alpnProtocols,
        message:
          "HTTP/3 (h3) detected in ALPN but not supported - falling back to TLS tunnel",
      });
    }

    handleTlsTunnel(buffered);
    return true;
  }

  function handleData(chunk: Buffer) {
    proxyLog("mitm-handle-data", { length: chunk.length });
    buffered = buffered.length === 0 ? chunk : Buffer.concat([buffered, chunk]);
    if (classify()) {
      return;
    }
  }

  function handleClientError(error: Error) {
    if (settled) {
      return;
    }
    proxyLogger?.warn("MITM tunnel client error", {
      error,
      host: originalHostname,
    });
    cleanup();
    clientSocket.destroy();
  }

  function handleClientClose() {
    if (settled) {
      return;
    }
    cleanup();
  }

  clientSocket.once("error", handleClientError);
  clientSocket.once("close", handleClientClose);
  clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");

  if (!classify()) {
    clientSocket.on("data", onData);
  }
}

function handleHttp2Connection(
  socket: TLSSocket,
  context: ProxyContext,
  target: ProxyTarget
) {
  // Use createServer (plain) because the socket is already a TLSSocket (decrypted).
  // createSecureServer would attempt another TLS handshake.
  const server = http2.createServer();
  server.on("stream", (stream, headers) => {
    handleHttp2Stream(stream, headers, context, target);
  });
  server.emit("connection", socket);
}

async function handleHttp2Stream(
  stream: http2.ServerHttp2Stream,
  headers: http2.IncomingHttpHeaders,
  context: ProxyContext,
  target: ProxyTarget
) {
  const method = (headers[":method"] as string) || "GET";
  const path = (headers[":path"] as string) || "/";
  const authority = (headers[":authority"] as string) || target.url.host;

  // We need to forward this to the upstream.
  // We can reuse forwardHttpRequestViaHttp2 if the upstream is H2,
  // or forwardHttpRequestViaHttp1 if upstream is H1.
  // The target.cmuxProxy logic in rewriteTarget might have already decided the upstream protocol/port.

  // However, forwardHttpRequest* functions expect IncomingMessage/ServerResponse.
  // We need to adapt or write a new forwarder for H2 streams.
  // For simplicity and robustness, let's write a dedicated H2 stream forwarder.

  proxyLog("http2-mitm-request", {
    username: context.username,
    method,
    path,
    authority,
    targetHost: target.url.hostname,
  });


  try {
    if (shouldAttemptHttp2(target)) {

      await forwardHttp2StreamToHttp2(stream, headers, target, context);
    } else {

      await forwardHttp2StreamToHttp1(stream, headers, target, context);
    }
  } catch (error) {
    console.error("handleHttp2Stream: error forwarding", error);
    proxyWarn("http2-mitm-forward-error", {
      error,
      path,
      host: target.url.hostname,
    });
    if (!stream.closed) {
      stream.respond({ ":status": 502 });
      stream.end();
    }
  }
}

async function forwardHttp2StreamToHttp2(
  clientStream: http2.ServerHttp2Stream,
  clientHeaders: http2.IncomingHttpHeaders,
  target: ProxyTarget,
  _context: ProxyContext
) {

  const session = await getHttp2SessionFor(target);

  
  const upstreamHeaders = { ...clientHeaders };
  // Filter pseudo-headers and connection-specific headers
  for (const key of Object.keys(upstreamHeaders)) {
    if (key.startsWith(":") || HOP_BY_HOP_HEADERS.has(key)) {
      delete upstreamHeaders[key];
    }
    if (key === "host" && target.cmuxProxy) {
      delete upstreamHeaders[key];
    }
  }
  
  // Re-add pseudo headers
  upstreamHeaders[":method"] = clientHeaders[":method"];
  upstreamHeaders[":path"] = clientHeaders[":path"];
  upstreamHeaders[":scheme"] = "https"; // We are always HTTPS if we are here? Or match target.
  upstreamHeaders[":authority"] = target.url.host;

  if (target.cmuxProxy) {
     injectCmuxProxyHeaders(upstreamHeaders as Record<string, string>, target.cmuxProxy);
     upstreamHeaders[":authority"] = target.url.host; 
  }


  const upstreamStream = session.request(upstreamHeaders);


  upstreamStream.on("response", (responseHeaders) => {

    clientStream.respond(responseHeaders);
  });

  upstreamStream.pipe(clientStream);
  clientStream.pipe(upstreamStream);

  upstreamStream.on("error", (err) => {
     console.error("Upstream stream error:", err);
     if (!clientStream.closed) clientStream.close(http2.constants.NGHTTP2_INTERNAL_ERROR);
  });
  
  clientStream.on("error", (err) => {
      console.error("Client stream error:", err);
      if (!upstreamStream.closed) upstreamStream.close(http2.constants.NGHTTP2_INTERNAL_ERROR);
  });
}

async function forwardHttp2StreamToHttp1(
  clientStream: http2.ServerHttp2Stream,
  clientHeaders: http2.IncomingHttpHeaders,
  target: ProxyTarget,
  _context: ProxyContext
) {
    // This is a bit more complex: H2 stream -> H1 request
    // We can use the 'http2' compatibility or just manual mapping.
    
    const method = (clientHeaders[":method"] as string) || "GET";
    const path = (clientHeaders[":path"] as string) || "/";
    
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries(clientHeaders)) {
        if (key.startsWith(":") || HOP_BY_HOP_HEADERS.has(key)) continue;
        if (key === "host" && target.cmuxProxy) continue;
        if (Array.isArray(value)) headers[key] = value.join(", ");
        else if (value) headers[key] = value;
    }
    
    injectCmuxProxyHeaders(headers, target.cmuxProxy);
    if (!target.cmuxProxy) {
        headers["host"] = target.url.host;
    }

    const agent = target.secure ? HTTPS1_KEEP_ALIVE_AGENT : HTTP1_KEEP_ALIVE_AGENT;
    const requestOptions = {
      protocol: target.secure ? "https:" : "http:",
      hostname: target.url.hostname,
      port: target.connectPort,
      method,
      path,
      headers,
      agent,
    };

    const httpModule = target.secure ? https : http;
    const proxyReq = httpModule.request(requestOptions, (proxyRes) => {
        const responseHeaders: http2.OutgoingHttpHeaders = {
            ":status": proxyRes.statusCode || 200,
        };
        for (const [key, value] of Object.entries(proxyRes.headers)) {
            if (HOP_BY_HOP_HEADERS.has(key)) continue;
            responseHeaders[key] = value;
        }
        clientStream.respond(responseHeaders);
        proxyRes.pipe(clientStream);
    });

    proxyReq.on("error", (_err) => {
        if (!clientStream.closed) {
            clientStream.respond({ ":status": 502 });
            clientStream.end();
        }
    });

    clientStream.pipe(proxyReq);
}



function deriveRoute(url: string): ProxyRoute | null {
  if (process.env.TEST_CMUX_PROXY_ORIGIN) {
      try {
        const parsed = new URL(url);
        if (parsed.hostname.includes("cmux-test-base-8080")) {
            return {
                morphId: "test",
                scope: "base",
                domainSuffix: "cmux.local",
                cmuxProxyOrigin: process.env.TEST_CMUX_PROXY_ORIGIN
            };
        }
        if (parsed.hostname.includes("cmux-test-ws-8083")) {
            return {
                morphId: "test",
                scope: "ws",
                domainSuffix: "cmux.local",
                cmuxProxyOrigin: "http://127.0.0.1:8083"
            };
        }
      } catch (_e) { /* ignore */ }
  }

  try {
    const parsed = new URL(url);
    const hostname = parsed.hostname.toLowerCase();
    const protocol = parsed.protocol === "http:" ? "http:" : "https:";
    const morphMatch = hostname.match(/^port-(\d+)-morphvm-([^.]+)(\..+)$/);
    if (morphMatch) {
      const morphId = morphMatch[2];
      if (morphId) {
        // const morphSuffix = morphMatch[3];
        const cmuxProxyOrigin = process.env.TEST_CMUX_PROXY_ORIGIN || `http://port-${CMUX_PROXY_PORT}-morphvm-${morphId}.http.cloud.morph.so`;
        return {
          morphId,
          scope: "base",
          domainSuffix: "cmux.app",
          cmuxProxyOrigin,
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
        cmuxProxyOrigin: `${protocol}//port-${CMUX_PROXY_PORT}-morphvm-${morphId}${DEFAULT_MORPH_DOMAIN_SUFFIX}`,
      };
    }
  } catch (error) {
    console.error("Failed to derive route", error);
    return null;
  }
  

  return null;
}
