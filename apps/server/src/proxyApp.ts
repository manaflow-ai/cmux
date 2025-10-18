import { api } from "@cmux/convex/api";
import express from "express";
import type { IncomingMessage, Server } from "http";
import httpProxy from "http-proxy";
import { Buffer } from "node:buffer";
import path from "node:path";
import { getConvex } from "./utils/convexClient";
import { serverLogger } from "./utils/fileLogger";
import { DockerVSCodeInstance } from "./vscode/DockerVSCodeInstance";
import { VSCodeInstance } from "./vscode/VSCodeInstance";

// Port cache to avoid hammering Docker
interface PortCacheEntry {
  ports: { [key: string]: string };
  timestamp: number;
}
const portCache = new Map<string, PortCacheEntry>();
const PORT_CACHE_DURATION = 2000; // 2 seconds

// Helper function to parse host header
function parseHostHeader(
  host: string
): { containerName: string; targetPort: string } | null {
  if (!host) return null;

  const hostParts = host.split(".");
  if (hostParts.length >= 3) {
    return {
      containerName: hostParts[0],
      targetPort: hostParts[1],
    };
  }
  return null;
}

// Loading screen HTML
const loadingScreen = `
  <!DOCTYPE html>
  <html>
  <head>
    <title>Starting VSCode Container</title>
    <style>
      body {
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        display: flex;
        flex-direction: column;
        justify-content: center;
        align-items: center;
        height: 100vh;
        margin: 0;
        background-color: #1e1e1e;
        color: #fff;
      }
      .spinner {
        border: 4px solid #333;
        border-top: 4px solid #007acc;
        border-radius: 50%;
        width: 50px;
        height: 50px;
        animation: spin 1s linear infinite;
        margin-bottom: 20px;
      }
      @keyframes spin {
        0% { transform: rotate(0deg); }
        100% { transform: rotate(360deg); }
      }
      .message {
        font-size: 18px;
        margin-bottom: 10px;
      }
      .container-name {
        font-family: monospace;
        color: #007acc;
      }
    </style>
    <script>
      // Auto-refresh every 2 seconds
      setTimeout(() => {
        window.location.reload();
      }, 2000);
    </script>
  </head>
  <body>
    <div class="spinner"></div>
    <div class="message">Starting VSCode container</div>
    <div class="container-name">{{containerName}}</div>
    <div style="margin-top: 20px; font-size: 14px; color: #888;">
      This page will automatically refresh...
    </div>
  </body>
  </html>
`;

// Map known port names to container ports
const KNOWN_PORT_MAPPINGS: { [key: string]: string } = {
  vscode: "39378",
  worker: "39377",
  extension: "39376",
  proxy: "39379",
  vnc: "39380",
  cdp: "39381",
  xterm: "39383",
};

// Check if container exists in Docker
async function checkContainerExists(containerName: string): Promise<boolean> {
  const docker = DockerVSCodeInstance.getDocker();

  try {
    const containers = await docker.listContainers({
      all: true,
      filters: { name: [containerName] },
    });

    return containers.length > 0;
  } catch (error) {
    serverLogger.error(`Failed to check container existence:`, error);
    return false;
  }
}

// Get actual host port for a container port from Docker
async function getActualPortFromDocker(
  containerName: string,
  containerPort: string
): Promise<string | null> {
  // Check cache first
  const cached = portCache.get(containerName);
  if (cached && Date.now() - cached.timestamp < PORT_CACHE_DURATION) {
    return cached.ports[containerPort] || null;
  }

  const docker = DockerVSCodeInstance.getDocker();

  try {
    const containers = await docker.listContainers({
      all: true,
      filters: { name: [containerName] },
    });

    if (containers.length === 0) {
      return null;
    }

    const container = docker.getContainer(containers[0].Id);
    const containerInfo = await container.inspect();

    if (!containerInfo.State.Running) {
      // Clear cache for stopped containers
      portCache.delete(containerName);
      return null;
    }

    const ports = containerInfo.NetworkSettings.Ports;
    const portMapping: { [key: string]: string } = {};

    // Extract all port mappings
    for (const [containerPortKey, hostPorts] of Object.entries(ports)) {
      if (hostPorts && hostPorts[0]?.HostPort) {
        // Extract just the port number (remove /tcp suffix)
        const portNum = containerPortKey.split("/")[0];
        portMapping[portNum] = hostPorts[0].HostPort;
      }
    }

    // Update cache
    portCache.set(containerName, {
      ports: portMapping,
      timestamp: Date.now(),
    });

    return portMapping[containerPort] || null;
  } catch (error) {
    serverLogger.error(
      `Failed to get port mapping for container ${containerName}:`,
      error
    );
    return null;
  }
}

export function createProxyApp({
  publicPath,
}: {
  publicPath: string;
}): express.Application {
  const app = express();

  // app.use(express.static(publicPath));
  const staticHandler = express.static(publicPath, {});

  // Main request handler
  app.use(
    async (
      req: express.Request,
      res: express.Response,
      next: express.NextFunction
    ) => {
      const host = req.get("host");
      if (!host) {
        return res.status(400).send("Host header is required");
      }

      // if no subdomain, return "cmux hello world"
      if (!host.includes(".")) {
        // Check if this is a static asset request
        const hasExtension = path.extname(req.url) !== "";
        const isAssets = req.url.startsWith("/assets");

        if (hasExtension || isAssets) {
          // Serve static files for assets or files with extensions
          return staticHandler(req, res, next);
        } else {
          // For all other routes (no extension), serve index.html for SPA routing
          return res.sendFile(path.join(publicPath, "index.html"));
        }
      }

      // Parse format: containerName.port.localhost:9776
      const parsed = parseHostHeader(host);
      if (!parsed) {
        return res
          .status(400)
          .send(
            "Invalid subdomain format. Expected: containerName.port.localhost:9776"
          );
      }

      const { containerName, targetPort } = parsed;
      const fullContainerName = containerName.startsWith("cmux-")
        ? containerName
        : `cmux-${containerName}`;

      // Determine which container port we need based on the target port
      let containerPort: string;

      // Check if targetPort is a known port name (vscode, worker, extension)
      if (KNOWN_PORT_MAPPINGS[targetPort]) {
        containerPort = KNOWN_PORT_MAPPINGS[targetPort];
      } else {
        // Otherwise, treat it as a direct container port number
        containerPort = targetPort;
      }

      // First, try to get the port directly from Docker
      const actualPort = await getActualPortFromDocker(
        fullContainerName,
        containerPort
      );

      if (actualPort) {
        // Container is running, proxy the request
        const proxy = httpProxy.createProxyServer({
          target: `http://localhost:${actualPort}`,
          changeOrigin: true,
          // Increase timeout for long-running requests
          proxyTimeout: 120000, // 120 seconds
          timeout: 120000, // 120 seconds
        });

        // Handle proxy errors
        proxy.on("error", (err: Error) => {
          serverLogger.error(
            `HTTP proxy error for ${fullContainerName}:${actualPort}:`,
            err.message
          );
          if (!res.headersSent) {
            res.status(502).send(`Proxy error: ${err.message}`);
          }
        });

        // Proxy the request
        proxy.web(req, res);
        return;
      }

      // Container not running or doesn't exist in Docker
      // Check if it should exist by querying Convex
      const teamParam = (req.query?.team as string) || "";
      let taskRun = null;
      if (teamParam) {
        try {
          taskRun = await getConvex().query(api.taskRuns.getByContainerName, {
            teamSlugOrId: teamParam,
            containerName: fullContainerName,
          });
        } catch (e) {
          serverLogger.error("Convex lookup failed in proxyApp:", e);
        }
      }

      if (!taskRun || !taskRun.vscode) {
        return res.status(404).send("Container not found");
      }

      // Container should exist but isn't running
      if (taskRun.vscode.status === "stopped") {
        // Try to restart it
        const instance = VSCodeInstance.getInstance(taskRun._id);
        if (!instance) {
          // Need to create a new instance
          const newInstance = new DockerVSCodeInstance({
            taskRunId: taskRun._id,
            taskId: taskRun.taskId,
            workspacePath: taskRun.worktreePath,
            teamSlugOrId: teamParam || "default",
          });

          // Start the container
          newInstance.start().catch((err) => {
            serverLogger.error(
              `Failed to start container ${fullContainerName}:`,
              err
            );
          });
        } else if (instance instanceof DockerVSCodeInstance) {
          instance.start().catch((err) => {
            serverLogger.error(
              `Failed to restart container ${fullContainerName}:`,
              err
            );
          });
        }
      }

      // Show loading screen while container is starting
      return res.send(
        loadingScreen.replace("{{containerName}}", containerName)
      );
    }
  );

  return app;
}

// Function to setup WebSocket upgrade handling on the HTTP server
export function setupWebSocketProxy(server: Server) {
  server.on(
    "upgrade",
    async (request: IncomingMessage, socket: any, head: Buffer) => {
      // Check if this is a Socket.IO request - let Socket.IO handle it
      const url = request.url || "";
      if (url.startsWith("/socket.io/")) {
        // This is a Socket.IO connection, don't handle it here
        return;
      }

      const host = request.headers.host;

      if (!host) {
        socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
        return;
      }

      // Also check if the host matches the proxy pattern
      // Socket.IO requests typically go to localhost:9776 directly
      // Proxy requests go to containerName.port.localhost:9776
      if (!host.includes(".localhost:") && !host.match(/\.[0-9]+\./)) {
        // This is likely a direct Socket.IO connection, not a proxy request
        return;
      }

      // Parse the host header
      const parsed = parseHostHeader(host);
      if (!parsed) {
        socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
        return;
      }

      const { containerName, targetPort } = parsed;
      const fullContainerName = containerName.startsWith("cmux-")
        ? containerName
        : `cmux-${containerName}`;

      // Determine container port
      let containerPort: string;

      // Check if targetPort is a known port name (vscode, worker, extension)
      if (KNOWN_PORT_MAPPINGS[targetPort]) {
        containerPort = KNOWN_PORT_MAPPINGS[targetPort];
      } else {
        // Otherwise, treat it as a direct container port number
        containerPort = targetPort;
      }

      // Get the actual host port from Docker
      const actualPort = await getActualPortFromDocker(
        fullContainerName,
        containerPort
      );

      if (!actualPort) {
        serverLogger.error(
          `WebSocket upgrade failed: Port ${targetPort} (container port ${containerPort}) not mapped for container ${containerName}`
        );
        socket.end("HTTP/1.1 404 Not Found\r\n\r\n");
        return;
      }

      // Create http-proxy for WebSocket with better timeout settings
      const proxy = httpProxy.createProxyServer({
        target: `ws://localhost:${actualPort}`,
        ws: true,
        changeOrigin: true,
        // Add timeout settings to prevent premature disconnections
        proxyTimeout: 0, // Disable timeout for WebSocket connections
        timeout: 0, // Disable timeout
      });

      // Keep the socket alive
      socket.setKeepAlive(true, 30000); // Send keepalive every 30 seconds
      socket.setNoDelay(true); // Disable Nagle algorithm for lower latency

      // Handle proxy errors
      proxy.on("error", (err: Error) => {
        serverLogger.error(
          `WebSocket proxy error for ${containerName}:${actualPort}:`,
          err.message
        );
        if (!socket.destroyed) {
          socket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        }
      });

      proxy.on("proxyReqWs", (proxyReq, req, socket) => {
        // Log WebSocket upgrade for debugging
        serverLogger.info(
          `WebSocket upgrade for ${containerName}:${actualPort} established`
        );
      });

      proxy.ws(request, socket, head);
    }
  );
}

// Augment Express Request interface
declare global {
  namespace Express {
    interface Request {
      containerName?: string;
      targetPort?: string;
    }
  }
}
