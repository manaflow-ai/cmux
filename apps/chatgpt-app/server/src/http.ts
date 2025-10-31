import { createServer } from "node:http";
import { parse } from "node:url";
import { randomUUID } from "node:crypto";

import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp";
import type { IncomingMessage, ServerResponse } from "node:http";

import { mcpServer } from "./index";

const PORT = Number(process.env.CMUX_CHATGPT_HTTP_PORT ?? 2091);

const transport = new StreamableHTTPServerTransport({
  sessionIdGenerator: undefined,
});

async function startHttpServer(): Promise<void> {
  await mcpServer.connect(transport);

  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const url = parse(req.url ?? "", true);

    if (!url.pathname || !url.pathname.startsWith("/mcp")) {
      res.writeHead(404).end("Not Found");
      return;
    }

    if (
      req.method === "GET" &&
      (!req.headers.accept || !req.headers.accept.includes("text/event-stream"))
    ) {
      req.headers.accept = "text/event-stream";
    }

    try {
      await transport.handleRequest(req as any, res as any);
    } catch (error) {
      console.error("[cmux-chatgpt] HTTP transport error", error);
      if (!res.headersSent) {
        res.writeHead(500).end("Internal Server Error");
      }
    }
  });

  server.listen(PORT, () => {
    console.log(`[cmux-chatgpt] HTTP MCP server listening on http://127.0.0.1:${PORT}/mcp`);
  });
}

startHttpServer().catch((error) => {
  console.error("[cmux-chatgpt] Failed to start HTTP MCP server", error);
  process.exit(1);
});
