import { execFile, spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { access, unlink } from "node:fs/promises";
import {
  createServer as createHttpServer,
  request as httpRequest,
  type IncomingMessage,
  type OutgoingHttpHeaders,
  type Server as HttpServer,
  type ServerResponse,
} from "node:http";
import { connect as connectSocket, type AddressInfo } from "node:net";
import type { Duplex } from "node:stream";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";

type Logger = {
  info: (message: string, ...args: unknown[]) => void;
  warn: (message: string, ...args: unknown[]) => void;
  error: (message: string, ...args: unknown[]) => void;
  debug?: (message: string, ...args: unknown[]) => void;
};

const execFileAsync = promisify(execFile);
const PROXY_HOST = "127.0.0.1";
const DEFAULT_PROXY_PORT = 0;
const SOCKET_READY_TIMEOUT_MS = 15_000;
const FRAME_ANCESTORS_HEADER =
  "frame-ancestors 'self' https://cmux.local http://cmux.local https://www.cmux.sh https://cmux.sh https://www.cmux.dev https://cmux.dev http://localhost:5173 http://cmux-vscode.localhost https://cmux-vscode.localhost http://cmux-vscode.local https://cmux-vscode.local;";

let resolvedVSCodeExecutable: string | null = null;
let currentServeWebBaseUrl: string | null = null;

export type VSCodeServeWebHandle = {
  process: ChildProcess;
  executable: string;
  proxyPort: number | null;
  proxyServer: HttpServer | null;
  socketPath: string | null;
};

export function getVSCodeServeWebBaseUrl(): string | null {
  return currentServeWebBaseUrl;
}

export async function waitForVSCodeServeWebBaseUrl(
  timeoutMs = 15_000
): Promise<string | null> {
  if (currentServeWebBaseUrl) {
    return currentServeWebBaseUrl;
  }

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (currentServeWebBaseUrl) {
      return currentServeWebBaseUrl;
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }

  return currentServeWebBaseUrl;
}

export async function ensureVSCodeServeWeb(
  logger: Logger,
  options?: { port?: number }
): Promise<VSCodeServeWebHandle | null> {
  logger.info("Ensuring VS Code serve-web availability...");

  const executable = await getVSCodeExecutable(logger);
  if (!executable) {
    logger.warn(
      "VS Code CLI executable unavailable; serve-web will not be launched."
    );
    return null;
  }

  if (process.platform === "win32") {
    logger.warn(
      "Unix socket mode for VS Code serve-web is unavailable on Windows; skipping launch."
    );
    return null;
  }

  const socketPath = createSocketPath();
  const requestedPort = options?.port ?? DEFAULT_PROXY_PORT;

  let child: ChildProcess | null = null;

  try {
    await removeStaleSocket(socketPath, logger);

    logger.info(
      `Starting VS Code serve-web using executable ${executable} with socket ${socketPath}...`
    );

    child = spawn(
      executable,
      [
        "serve-web",
        "--accept-server-license-terms",
        "--without-connection-token",
        "--socket-path",
        socketPath,
      ],
      {
        detached: true,
        stdio: ["ignore", "pipe", "pipe"],
      }
    );

    attachServeWebProcessLogging(child, logger);

    child!.on("error", (error) => {
      logger.error("VS Code serve-web process error:", error);
    });

    child!.on("exit", (code, signal) => {
      const exitMessage = `VS Code serve-web process exited${
        typeof code === "number" ? ` with code ${code}` : ""
      }${signal ? ` due to signal ${signal}` : ""}.`;
      if (code === 0 && !signal) {
        logger.info(exitMessage);
      } else {
        logger.warn(exitMessage);
      }
      if (currentServeWebBaseUrl) {
        logger.info("Clearing cached VS Code serve-web base URL");
        currentServeWebBaseUrl = null;
      }
    });

    child!.unref();

    await waitForSocket(socketPath, logger);

    logger.info(
      "VS Code serve-web socket is ready; starting local proxy server..."
    );
    const { server: proxyServer, port: proxyPort } = await startServeWebProxy({
      logger,
      socketPath,
      requestedPort,
    });

    const baseUrl = `http://${PROXY_HOST}:${proxyPort}`;
    currentServeWebBaseUrl = baseUrl;

    logger.info(
      `Launched VS Code serve-web proxy at ${baseUrl} (pid ${child.pid ?? "unknown"}).`
    );

    await warmUpVSCodeServeWeb(baseUrl, logger);

    return {
      process: child!,
      executable,
      proxyPort,
      proxyServer,
      socketPath,
    };
  } catch (error) {
    logger.error("Failed to launch VS Code serve-web via unix socket:", error);
    if (child && !child.killed && child.exitCode === null) {
      try {
        child.kill();
      } catch (killError) {
        logger.warn(
          "Failed to terminate VS Code serve-web after launch failure:",
          killError
        );
      }
    }
    try {
      await unlink(socketPath);
    } catch {
      // ignore cleanup errors here
    }
    currentServeWebBaseUrl = null;
    return null;
  }
}

export function stopVSCodeServeWeb(
  handle: VSCodeServeWebHandle | null,
  logger: Logger
): void {
  if (!handle) {
    return;
  }

  const { process: child } = handle;
  if (child.killed || child.exitCode !== null || child.signalCode !== null) {
    return;
  }

  logger.info("Stopping VS Code serve-web process...");
  currentServeWebBaseUrl = null;
  if (handle.proxyServer) {
    handle.proxyServer.close((error) => {
      if (error) {
        logger.warn(
          "Error while shutting down VS Code serve-web proxy:",
          error
        );
      }
    });
  }
  if (handle.socketPath) {
    void unlink(handle.socketPath).catch((error) => {
      if (
        error &&
        typeof error === "object" &&
        "code" in error &&
        (error as NodeJS.ErrnoException).code === "ENOENT"
      ) {
        return;
      }
      logger.warn(
        `Failed to remove VS Code serve-web socket at ${handle.socketPath}:`,
        error
      );
    });
  }
  try {
    child.kill();
  } catch (error) {
    logger.error("Failed to stop VS Code serve-web process:", error);
  }
}

async function getVSCodeExecutable(logger: Logger) {
  logger.info("Attempting to resolve VS Code CLI executable for serve-web.");
  const executable = await resolveVSCodeExecutable(logger);
  if (!executable) {
    return null;
  }

  try {
    if (process.platform !== "win32") {
      await access(executable, fsConstants.X_OK);
    }
    return executable;
  } catch (error) {
    logger.error(`VS Code CLI at ${executable} is not executable:`, error);
    return null;
  }
}

async function resolveVSCodeExecutable(logger: Logger) {
  if (resolvedVSCodeExecutable) {
    return resolvedVSCodeExecutable;
  }

  const lookups =
    process.platform === "win32"
      ? [
          { command: "where", args: ["code.cmd"] },
          { command: "where", args: ["code.exe"] },
          { command: "where", args: ["code"] },
        ]
      : [{ command: "/usr/bin/env", args: ["which", "code"] }];

  for (const { command, args } of lookups) {
    try {
      const { stdout } = await execFileAsync(command, args);
      const candidate = stdout
        .split(/\r?\n/)
        .map((line) => line.trim())
        .find((line) => line.length > 0);

      if (candidate) {
        resolvedVSCodeExecutable = candidate;
        logger.info(`Resolved VS Code CLI executable: ${candidate}`);
        break;
      }
    } catch (error) {
      logger.debug?.(`VS Code CLI lookup with ${command} failed:`, error);
    }
  }

  if (!resolvedVSCodeExecutable && process.env.SHELL) {
    try {
      const { stdout } = await execFileAsync(process.env.SHELL, [
        "-lc",
        "command -v code",
      ]);
      const candidate = stdout
        .split(/\r?\n/)
        .map((line) => line.trim())
        .find((line) => line.length > 0);
      if (candidate) {
        resolvedVSCodeExecutable = candidate;
        logger.info(
          `Resolved VS Code CLI executable via shell lookup: ${candidate}`
        );
      }
    } catch (error) {
      logger.debug?.(
        `VS Code CLI SHELL lookup failed (${process.env.SHELL}):`,
        error
      );
    }
  }

  return resolvedVSCodeExecutable;
}

async function warmUpVSCodeServeWeb(baseUrl: string, logger: Logger) {
  const warmupDeadline = Date.now() + 10_000;
  const endpoint = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;

  while (Date.now() < warmupDeadline) {
    try {
      const response = await fetch(endpoint, { redirect: "manual" });
      if (response.status === 200) {
        logger.info("VS Code serve-web warm-up succeeded.");
        return;
      }
      logger.debug?.(
        `VS Code serve-web warm-up response: ${response.status} ${response.statusText}`
      );
    } catch (error) {
      logger.debug?.("VS Code serve-web warm-up attempt failed:", error);
    }

    await new Promise<void>((resolve) => setTimeout(resolve, 500));
  }

  logger.warn(
    "VS Code serve-web did not respond with HTTP 200 during warm-up window."
  );
}

function attachServeWebProcessLogging(child: ChildProcess, logger: Logger) {
  const debugLog = logger.debug ?? logger.info;

  pipeStreamLines(child.stdout, (line) => {
    debugLog(`[VS Code serve-web stdout] ${line}`);
  });

  pipeStreamLines(child.stderr, (line) => {
    logger.warn(`[VS Code serve-web stderr] ${line}`);
  });
}

function pipeStreamLines(
  stream: NodeJS.ReadableStream | null | undefined,
  onLine: (line: string) => void
) {
  if (!stream) {
    return;
  }

  let buffered = "";

  stream.on("data", (chunk: Buffer | string) => {
    buffered += chunk.toString();

    let newlineIndex = buffered.indexOf("\n");
    while (newlineIndex !== -1) {
      const line = buffered.slice(0, newlineIndex).replace(/\r$/, "");
      onLine(line);
      buffered = buffered.slice(newlineIndex + 1);
      newlineIndex = buffered.indexOf("\n");
    }
  });

  stream.on("end", () => {
    if (buffered.length > 0) {
      onLine(buffered.replace(/\r$/, ""));
    }
  });
}

function createSocketPath(): string {
  const filename = `cmux-vscode-${process.pid}-${Date.now()}.sock`;
  return path.join(tmpdir(), filename);
}

async function removeStaleSocket(socketPath: string, logger: Logger) {
  try {
    await unlink(socketPath);
    logger.info(`Removed stale VS Code serve-web socket at ${socketPath}`);
  } catch (error) {
    if (
      error &&
      typeof error === "object" &&
      "code" in error &&
      (error as NodeJS.ErrnoException).code === "ENOENT"
    ) {
      return;
    }
    logger.debug?.("Failed to remove stale VS Code serve-web socket:", error);
  }
}

async function waitForSocket(socketPath: string, logger: Logger) {
  const deadline = Date.now() + SOCKET_READY_TIMEOUT_MS;

  while (Date.now() < deadline) {
    try {
      await access(socketPath, fsConstants.F_OK);
      return;
    } catch (error) {
      if (
        error &&
        typeof error === "object" &&
        "code" in error &&
        (error as NodeJS.ErrnoException).code === "ENOENT"
      ) {
        await new Promise((resolve) => setTimeout(resolve, 100));
        continue;
      }
      throw error;
    }
  }

  throw new Error(
    `VS Code serve-web socket ${socketPath} was not ready within ${SOCKET_READY_TIMEOUT_MS} ms`
  );
}

async function startServeWebProxy({
  logger,
  socketPath,
  requestedPort,
}: {
  logger: Logger;
  socketPath: string;
  requestedPort: number;
}): Promise<{ server: HttpServer; port: number }> {
  const server = createHttpServer((req, res) => {
    forwardHttpRequest({
      logger,
      socketPath,
      request: req,
      response: res,
    });
  });

  server.on("upgrade", (req, clientSocket, head) => {
    handleWebSocketUpgrade({
      logger,
      socketPath,
      request: req,
      clientSocket,
      head,
    });
  });

  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error) => {
      server.off("error", onError);
      reject(error);
    };

    server.once("error", onError);
    server.listen(requestedPort, PROXY_HOST, () => {
      server.off("error", onError);
      resolve();
    });
  });

  const address = server.address();
  if (!address || typeof address === "string") {
    server.close();
    throw new Error(
      "Failed to determine VS Code serve-web proxy server address"
    );
  }

  return { server, port: (address as AddressInfo).port };
}

function forwardHttpRequest({
  logger,
  socketPath,
  request,
  response,
}: {
  logger: Logger;
  socketPath: string;
  request: IncomingMessage;
  response: ServerResponse;
}) {
  const targetPath = request.url ?? "/";
  const proxyReq = httpRequest(
    {
      socketPath,
      method: request.method,
      path: targetPath,
      headers: request.headers,
    },
    (proxyRes) => {
      const headers = rewriteResponseHeaders(proxyRes.headers);

      if (request.method === "HEAD") {
        response.writeHead(proxyRes.statusCode ?? 200, headers);
        proxyRes.resume();
        response.end();
        return;
      }

      response.writeHead(proxyRes.statusCode ?? 200, headers);
      proxyRes.pipe(response);
    }
  );

  proxyReq.on("error", (error) => {
    logger.error("VS Code serve-web proxy HTTP error:", error);
    if (!response.destroyed) {
      response.writeHead(502, { "content-type": "text/plain" });
      response.end("Failed to reach VS Code serve-web backend.");
    }
  });

  request.pipe(proxyReq);
}

function rewriteResponseHeaders(
  headers: IncomingMessage["headers"]
): OutgoingHttpHeaders {
  const rewritten: OutgoingHttpHeaders = {};

  for (const [key, value] of Object.entries(headers)) {
    if (typeof value === "undefined") {
      continue;
    }
    rewritten[key] = value;
  }

  rewritten["content-security-policy"] = FRAME_ANCESTORS_HEADER;
  rewritten["access-control-allow-origin"] = "*";
  rewritten["access-control-allow-credentials"] = "true";
  rewritten["access-control-allow-methods"] =
    "GET,HEAD,POST,PUT,DELETE,PATCH,OPTIONS";
  rewritten["access-control-allow-headers"] =
    "*, Authorization, Content-Type, Content-Length, X-Requested-With";

  return rewritten;
}

function handleWebSocketUpgrade({
  logger,
  socketPath,
  request,
  clientSocket,
  head,
}: {
  logger: Logger;
  socketPath: string;
  request: IncomingMessage;
  clientSocket: Duplex;
  head: Buffer;
}) {
  const upstream = connectSocket(socketPath);

  upstream.on("connect", () => {
    const headerLines: string[] = [];
    for (const [name, value] of Object.entries(request.headers)) {
      if (typeof value === "undefined") {
        continue;
      }
      if (Array.isArray(value)) {
        for (const entry of value) {
          headerLines.push(`${name}: ${entry}`);
        }
      } else {
        headerLines.push(`${name}: ${value}`);
      }
    }

    const headers = [
      `${request.method ?? "GET"} ${request.url ?? "/"} HTTP/${request.httpVersion}`,
      ...headerLines,
      "",
      "",
    ].join("\r\n");

    upstream.write(headers);
    upstream.write(head);

    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });

  const closeWithError = (error: Error) => {
    logger.error("VS Code serve-web proxy WebSocket error:", error);
    try {
      clientSocket.destroy();
    } catch {
      // ignore
    }
    try {
      upstream.destroy();
    } catch {
      // ignore
    }
  };

  upstream.on("error", closeWithError);
  clientSocket.on("error", closeWithError);
}
