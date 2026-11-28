import { randomUUID } from "node:crypto";
import { unlink } from "node:fs/promises";
import { join } from "node:path";

const sourceRoot = join(import.meta.dir, "../../../..");
const bundledRoot = join(import.meta.dir, "..");
const sourceCatalog = join(sourceRoot, "cmux-tui/spec/resource-operations-v2.json");
const bundledCatalog = join(bundledRoot, "code-mode/resource-operations-v2.json");
const root = await Bun.file(sourceCatalog).exists() ? sourceRoot : bundledRoot;
const catalogPath = root === sourceRoot ? sourceCatalog : bundledCatalog;
const catalog = await Bun.file(catalogPath).json();
const sourceCloudCatalogPath = join(sourceRoot, "backend/catalog/cloud-operations.json");
const bundledCloudCatalogPath = join(bundledRoot, "cloud-operations.json");
const cloudCatalogPath = await Bun.file(sourceCloudCatalogPath).exists() ? sourceCloudCatalogPath : bundledCloudCatalogPath;
const cloudCatalog = await Bun.file(cloudCatalogPath).exists() ? await Bun.file(cloudCatalogPath).json() : { operations: {} };
const sourceRelayCatalogPath = join(sourceRoot, "backend/catalog/cloud-relay-operations.json");
const bundledRelayCatalogPath = join(bundledRoot, "cloud-relay-operations.json");
const relayCatalogPath = await Bun.file(sourceRelayCatalogPath).exists() ? sourceRelayCatalogPath : bundledRelayCatalogPath;
const relayCatalog = await Bun.file(relayCatalogPath).exists() ? await Bun.file(relayCatalogPath).json() : { operations: {} };
const allCatalogOperations = {
  ...relayCatalog.operations,
  ...catalog.operations,
  ...cloudCatalog.operations,
};
const runner = root === sourceRoot
  ? join(root, "scripts/cmux-next/cmux-code-mode-runner")
  : join(root, "bin/cmux-code-mode-runner");
const MAX_FRAME_BYTES = 1024 * 1024;
const MAX_OUTPUT_BYTES = 1024 * 1024;
const EXEC_TIMEOUT_MS = 30_000;
const encoder = new TextEncoder();
const activeExecutions = new Map();

const tools = [
  {
    name: "cmux_docs",
    description: "Search the cmux operation catalog without opening a session.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: { query: { type: "string", minLength: 1, description: "UTF-8 text, at most 256 bytes" } },
      required: ["query"],
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "cmux_exec",
    description: "Run a TypeScript cmux script in the locked-down code-mode sandbox.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: { script: { type: "string", minLength: 1, description: "UTF-8 TypeScript, at most 262144 bytes" } },
      required: ["script"],
    },
    annotations: { destructiveHint: false },
  },
];

function docs(query) {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  const results = Object.entries(allCatalogOperations)
    .filter(([name, descriptor]) => {
      const haystack = JSON.stringify([name, descriptor]).toLowerCase();
      return terms.every((term) => haystack.includes(term));
    })
    .slice(0, 20)
    .map(([name, descriptor]) => ({
      name,
      class: descriptor.class,
      target: descriptor.target,
      selectors: Object.keys(descriptor.params?.selectors ?? {}),
      fields: Object.keys(descriptor.params?.fields ?? {}),
      result: descriptor.result?.name ?? descriptor.result?.kind ?? "value",
    }));
  return JSON.stringify({ query, results });
}

async function execute(script, signal) {
  const path = `/tmp/cmux-code-mode-${randomUUID()}.ts`;
  await Bun.write(path, script);
  try {
    const child = Bun.spawn([runner, path], {
      detached: true,
      env: { ...process.env },
      stdout: "pipe",
      stderr: "pipe",
    });
    let timedOut = false;
    let cancelled = false;
    let killTimer;
    let terminated = false;
    const terminate = () => {
      if (terminated) return;
      terminated = true;
      try { process.kill(-child.pid, "SIGTERM"); } catch {}
      child.kill();
      killTimer = setTimeout(() => {
        try { process.kill(-child.pid, "SIGKILL"); } catch {}
      }, 250);
    };
    const cancel = () => {
      cancelled = true;
      terminate();
    };
    if (signal?.aborted) cancel();
    else signal?.addEventListener("abort", cancel, { once: true });
    const timer = setTimeout(() => { timedOut = true; terminate(); }, EXEC_TIMEOUT_MS);
    const read = async (stream) => {
      const reader = stream.getReader();
      const decoder = new TextDecoder();
      let text = "";
      let bytes = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        text += decoder.decode(value, { stream: true });
        if (bytes >= MAX_OUTPUT_BYTES) {
          terminate();
          text += "\n[output truncated]";
          break;
        }
      }
      return text;
    };
    try {
      const [stdout, stderr] = await Promise.all([read(child.stdout), read(child.stderr)]);
      const exitCode = await child.exited;
      return { exitCode, stdout, stderr, timedOut, cancelled };
    } finally {
      clearTimeout(timer);
      clearTimeout(killTimer);
      signal?.removeEventListener("abort", cancel);
    }
  } finally {
    await unlink(path).catch(() => {});
  }
}

function send(message) {
  const body = JSON.stringify(message);
  process.stdout.write(`${body}\n`);
}

async function handle(message) {
  const hasId = Object.hasOwn(message, "id");
  const id = hasId ? message.id : undefined;
  const respond = (payload) => {
    if (hasId) send({ jsonrpc: "2.0", id, ...payload });
  };
  if (message.method === "initialize") {
    return respond({ result: {
      protocolVersion: "2025-06-18",
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "cmux-code-mode", version: "0.1.0" },
    } });
  }
  if (message.method === "notifications/cancelled") {
    activeExecutions.get(message.params?.requestId)?.abort();
    return;
  }
  if (message.method?.startsWith("notifications/")) return;
  if (message.method === "tools/list") return respond({ result: { tools } });
  if (message.method !== "tools/call") {
    return respond({ error: { code: -32601, message: "method not found" } });
  }
  const name = message.params?.name;
  const args = message.params?.arguments ?? {};
  if (!args || typeof args !== "object" || Array.isArray(args)) throw new Error("arguments must be an object");
  let text;
  if (name === "cmux_docs") {
    if (Object.keys(args).some((key) => key !== "query")
      || typeof args.query !== "string" || !args.query.trim()
      || encoder.encode(args.query).byteLength > 256) {
      throw new Error("query must be a non-empty UTF-8 string of at most 256 bytes");
    }
    text = docs(args.query);
  } else if (name === "cmux_exec") {
    if (Object.keys(args).some((key) => key !== "script")
      || typeof args.script !== "string" || !args.script
      || encoder.encode(args.script).byteLength > 262144) {
      throw new Error("script must be a non-empty UTF-8 string of at most 262144 bytes");
    }
    const controller = new AbortController();
    if (hasId) activeExecutions.set(id, controller);
    try {
      text = await execute(args.script, controller.signal);
    } finally {
      if (hasId) activeExecutions.delete(id);
    }
  } else {
    throw new Error(`unknown tool: ${name}`);
  }
  const result = typeof text === "string" ? JSON.parse(text) : text;
  respond({ result: {
    content: [{ type: "text", text: JSON.stringify(result) }],
    ...(name === "cmux_exec" && result.exitCode !== 0 ? { isError: true } : {}),
  } });
}

function dispatch(message) {
  handle(message).catch((error) => {
    if (Object.hasOwn(message, "id")) {
      send({ jsonrpc: "2.0", id: message.id, error: { code: -32602, message: String(error?.message ?? error) } });
    }
  });
}

let pending = Buffer.alloc(0);
for await (const chunk of process.stdin) {
  pending = Buffer.concat([pending, Buffer.from(chunk)]);
  if (pending.length > MAX_FRAME_BYTES + 8192) {
    send({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "frame exceeds 1 MiB" } });
    process.exit(1);
  }
  while (true) {
    const end = pending.indexOf(10);
    if (end < 0) break;
    const body = pending.subarray(0, end).toString().replace(/\r$/, "");
    pending = pending.subarray(end + 1);
    if (Buffer.byteLength(body) > MAX_FRAME_BYTES) {
      send({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "frame exceeds 1 MiB" } });
      continue;
    }
    let message;
    try {
      message = JSON.parse(body);
    } catch (error) {
      send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: String(error?.message ?? error) } });
      continue;
    }
    if (!message || typeof message !== "object" || Array.isArray(message)
      || message.jsonrpc !== "2.0" || typeof message.method !== "string") {
      send({ jsonrpc: "2.0", id: message?.id ?? null, error: { code: -32600, message: "invalid JSON-RPC request" } });
      continue;
    }
    dispatch(message);
  }
}
