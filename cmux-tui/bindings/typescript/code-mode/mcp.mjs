import { randomUUID } from "node:crypto";
import { unlink } from "node:fs/promises";
import { join } from "node:path";

const root = join(import.meta.dir, "../../../..");
const catalogPath = join(root, "cmux-tui/spec/resource-operations-v2.json");
const catalog = await Bun.file(catalogPath).json();
const runner = process.env.CMUX_CODE_MODE_RUNNER
  || join(root, "scripts/cmux-next/cmux-code-mode-runner");

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
    const [stdout, stderr] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    const exitCode = await child.exited;
    return JSON.stringify({ exitCode, stdout, stderr });
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
  if (message.method === "notifications/initialized") return;
  if (message.method === "tools/list") return send({ jsonrpc: "2.0", id, result: { tools } });
  if (message.method !== "tools/call") {
    return send({ jsonrpc: "2.0", id, error: { code: -32601, message: "method not found" } });
  }
  const name = message.params?.name;
  const args = message.params?.arguments ?? {};
  let text;
  if (name === "cmux_docs") {
    if (typeof args.query !== "string" || !args.query.trim() || args.query.length > 256) {
      throw new Error("query must be a non-empty string of at most 256 characters");
    }
    text = docs(args.query);
  } else if (name === "cmux_exec") {
    if (typeof args.script !== "string" || !args.script || args.script.length > 262144) {
      throw new Error("script must be a non-empty string of at most 262144 characters");
    }
    text = await execute(args.script);
  } else {
    throw new Error(`unknown tool: ${name}`);
  }
  send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text }] } });
}

let pending = Buffer.alloc(0);
for await (const chunk of process.stdin) {
  pending = Buffer.concat([pending, Buffer.from(chunk)]);
  while (true) {
    const marker = pending.indexOf("\r\n\r\n");
    if (marker < 0) break;
    const headers = pending.subarray(0, marker).toString();
    const length = Number(headers.match(/content-length:\s*(\d+)/i)?.[1]);
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
