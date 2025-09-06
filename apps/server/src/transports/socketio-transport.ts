import { Server as SocketIOServer } from "socket.io";
import type { Server as HttpServer } from "node:http";
import type {
  ClientToServerEvents,
  ServerToClientEvents,
  InterServerEvents,
  SocketData,
} from "@cmux/shared";
import type { RealtimeServer, RealtimeSocket } from "../realtime.js";
import { serverLogger } from "../utils/fileLogger.js";
import { runWithAuth } from "../utils/requestContext.js";

export function createSocketIOTransport(httpServer: HttpServer): RealtimeServer {
  const allowedOriginsEnv = process.env.CMUX_ALLOWED_SOCKET_ORIGINS;
  const defaultAllowed = new Set([
    "http://localhost:5173",
    "https://cmux.local",
  ]);
  const dynamicAllowed = new Set(
    (allowedOriginsEnv?.split(",") ?? [])
      .map((s) => s.trim())
      .filter(Boolean)
  );

  const isOriginAllowed = (origin?: string | null) => {
    if (!origin) return true; // Electron/file:// often has no Origin
    try {
      const u = new URL(origin);
      if (defaultAllowed.has(origin) || dynamicAllowed.has(origin)) return true;
      // Allow localhost during development regardless of port
      if (u.hostname === "localhost" || u.hostname === "127.0.0.1") return true;
    } catch {
      // Non-URL origin strings: be permissive
      return true;
    }
    return false;
  };

  const io = new SocketIOServer<
    ClientToServerEvents,
    ServerToClientEvents,
    InterServerEvents,
    SocketData
  >(httpServer, {
    cors: {
      origin: (origin, callback) => {
        if (isOriginAllowed(origin)) return callback(null, true);
        serverLogger.warn("Blocked socket.io origin", { origin });
        callback(new Error("Not allowed by CORS"));
      },
      methods: ["GET", "POST"],
    },
    maxHttpBufferSize: 50 * 1024 * 1024, // 50MB to handle multiple images
    pingTimeout: 120000, // 120 seconds - match worker settings
    pingInterval: 30000, // 30 seconds - match worker settings
    allowEIO3: true, // Allow different Socket.IO versions
  });

  // Attach auth context from socket.io connection query param ?auth=JWT
  io.use((socket, next) => {
    const q = socket.handshake.query?.auth;
    const token = Array.isArray(q)
      ? q[0]
      : typeof q === "string"
        ? q
        : undefined;
    const qJson = socket.handshake.query?.auth_json;
    const tokenJson = Array.isArray(qJson)
      ? qJson[0]
      : typeof qJson === "string"
        ? qJson
        : undefined;
    runWithAuth(token, tokenJson, () => next());
  });

  return {
    onConnection(handler: (socket: RealtimeSocket) => void) {
      io.on("connection", handler);
    },
    emit(event, ...args) {
      io.emit(event, ...args);
    },
    async close() {
      await new Promise<void>((resolve) => {
        io.close(() => {
          serverLogger.info("Socket.io server closed");
          resolve();
        });
      });
    },
  };
}