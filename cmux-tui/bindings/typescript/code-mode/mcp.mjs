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
const runner = root === sourceRoot
  ? join(root, "scripts/cmux-next/cmux-code-mode-runner")
  : join(root, "bin/cmux-code-mode-runner");
const MAX_FRAME_BYTES = 1024 * 1024;
const MAX_OUTPUT_BYTES = 1024 * 1024;
const EXEC_TIMEOUT_MS = 30_000;
const encoder = new TextEncoder();

const tools = [
  {
    name: "cmux_docs",
    description: "Search the cmux operation catalog without opening a session.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: { query: { type: "string", minLength: 1, maxLength: 256 } },
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
      properties: { script: { type: "string", minLength: 1, maxLength: 262144 } },
      required: ["script"],
    },
    annotations: { destructiveHint: false },
  },
];

function docs(query) {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  const results = Object.entries(catalog.operations)
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

async function execute(script) {
  const path = `/tmp/cmux-code-mode-${randomUUID()}.ts`;
  await Bun.write(path, script);
  try {
    const child = Bun.spawn([runner, path], {
      env: { ...process.env },
      stdout: "pipe",
      stderr: "pipe",
    });
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill(); }, EXEC_TIMEOUT_MS);
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
          child.kill();
          text += "\n[output truncated]";
          break;
        }
      }
      return text;
    };
    try {
      const [stdout, stderr] = await Promise.all([read(child.stdout), read(child.stderr)]);
      const exitCode = await child.exited;
      return { exitCode, stdout, stderr, timedOut };
    } finally {
      clearTimeout(timer);
    }
  } finally {
    await unlink(path).catch(() => {});
  }
}

function send(message) {
  const body = JSON.stringify(message);
  process.stdout.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
}

async function handle(message) {
  const id = message.id;
  if (message.method === "initialize") {
    return send({ jsonrpc: "2.0", id, result: {
      protocolVersion: "2025-06-18",
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "cmux-code-mode", version: "0.1.0" },
    } });
  }
  if (message.method?.startsWith("notifications/")) return;
  if (message.method === "tools/list") return send({ jsonrpc: "2.0", id, result: { tools } });
  if (message.method !== "tools/call") {
    return send({ jsonrpc: "2.0", id, error: { code: -32601, message: "method not found" } });
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
    text = await execute(args.script);
  } else {
    throw new Error(`unknown tool: ${name}`);
  }
  const result = typeof text === "string" ? JSON.parse(text) : text;
  send({ jsonrpc: "2.0", id, result: {
    content: [{ type: "text", text: JSON.stringify(result) }],
    ...(name === "cmux_exec" && result.exitCode !== 0 ? { isError: true } : {}),
  } });
}

let pending = Buffer.alloc(0);
for await (const chunk of process.stdin) {
  pending = Buffer.concat([pending, Buffer.from(chunk)]);
  while (true) {
    const marker = pending.indexOf("\r\n\r\n");
    if (marker < 0) break;
    const headers = pending.subarray(0, marker).toString();
    const length = Number(headers.match(/content-length:\s*(\d+)/i)?.[1]);
    if (!Number.isSafeInteger(length) || length < 0 || length > MAX_FRAME_BYTES) {
      send({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "invalid or oversized Content-Length" } });
      process.exit(1);
    }
    if (!Number.isSafeInteger(length) || pending.length < marker + 4 + length) break;
    const body = pending.subarray(marker + 4, marker + 4 + length).toString();
    pending = pending.subarray(marker + 4 + length);
    let message;
    try {
      message = JSON.parse(body);
      await handle(message);
    } catch (error) {
      send({ jsonrpc: "2.0", id: message?.id ?? null, error: { code: -32602, message: String(error?.message ?? error) } });
    }
  }
}
