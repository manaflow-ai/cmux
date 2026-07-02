#!/usr/bin/env node
// Protocol smoke test for the cmux-computer-use MCP server.
// Spawns cmux-computer-use-mcp.mjs over stdio with the OFFICIAL MCP SDK client
// (real interop coverage for the dependency-free server), then:
// initialize -> tools/list -> tools/call.
//
//   node scripts/smoke.mjs                      # initialize + tools/list + computer_target
//   node scripts/smoke.mjs computer_apps        # ...plus call computer_apps
//   node scripts/smoke.mjs computer_state '{"app":"Calculator"}'
//
// Env is passed through, so CMUX_CU_CODEX/CMUX_CU_TIMEOUT_MS apply.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { ElicitRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const serverPath = join(here, "..", "cmux-computer-use-mcp.mjs");

const [toolName, toolArgsJson] = process.argv.slice(2);

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [serverPath],
  env: { ...process.env },
  stderr: "inherit",
});
// The human running this smoke consents to it driving the engine, so the
// per-app control elicitations are accepted here (and logged). Real agent
// sessions get the interactive Accept/Decline prompt instead.
const client = new Client(
  { name: "cmux-cu-smoke", version: "0.2.0" },
  { capabilities: { elicitation: {} } }
);
client.setRequestHandler(ElicitRequestSchema, async (request) => {
  console.log(`  [smoke] auto-accepting elicitation: ${request.params.message}`);
  return { action: "accept", content: {} };
});
await client.connect(transport);

const REQUIRED_TOOLS = [
  "computer_target",
  "computer_apps",
  "computer_open",
  "computer_state",
  "computer_screenshot",
  "computer_click",
  "computer_type",
  "computer_key",
  "computer_scroll",
  "computer_drag",
  "computer_action",
  "computer_windows",
];

const { tools } = await client.listTools();
console.log(`tools/list -> ${tools.length} tools:`);
for (const t of tools) console.log(`  - ${t.name}`);
const missing = REQUIRED_TOOLS.filter((name) => !tools.some((t) => t.name === name));
if (missing.length > 0) {
  console.error(`FAIL: missing required tools: ${missing.join(", ")}`);
  await client.close();
  process.exit(1);
}

let failed = false;

async function call(name, args = {}) {
  console.log(`\ntools/call ${name} ${JSON.stringify(args)}`);
  const res = await client.callTool({ name, arguments: args });
  for (const c of res.content ?? []) {
    if (c.type === "image") {
      console.log(`  [image ${c.mimeType}, ${Math.round(c.data.length * 0.75)} bytes]`);
    } else {
      const t = String(c.text ?? "");
      console.log(`  ${t.length > 800 ? t.slice(0, 800) + "\n  …[truncated]" : t}`);
    }
  }
  if (res.isError) {
    console.log("  (isError: true)");
    failed = true;
  }
  return res;
}

await call("computer_target");
if (toolName) await call(toolName, toolArgsJson ? JSON.parse(toolArgsJson) : {});

await client.close();
if (failed) {
  console.error("FAIL: a tool call returned isError");
  process.exit(1);
}
