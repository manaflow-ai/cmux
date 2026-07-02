#!/usr/bin/env node
// Verifies the per-app approval path: the codex app-server's
// `mcpServer/elicitation/request` must be forwarded to the MCP client as a
// real `elicitation/create` (approved by the human), and must fail closed
// (decline) for clients that never declared elicitation support.
//
// Uses scripts/fake-codex-app-server.mjs via CMUX_CU_CODEX, so it runs
// hermetically — no real codex install, auth, or GUI is touched.
//
//   node scripts/elicitation-smoke.mjs

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { ElicitRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import process from "node:process";

const here = dirname(fileURLToPath(import.meta.url));
const serverPath = join(here, "..", "cmux-computer-use-mcp.mjs");
const fakeCodex = join(here, "fake-codex-app-server.mjs");

async function run({ withElicitation, tool = "computer_apps", args = {} }) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    env: { ...process.env, CMUX_CU_CODEX: fakeCodex },
    stderr: "pipe",
  });
  const client = new Client(
    { name: "cu-elicitation-smoke", version: "0.0.1" },
    withElicitation ? { capabilities: { elicitation: {} } } : undefined
  );
  if (withElicitation) {
    client.setRequestHandler(ElicitRequestSchema, async (request) => {
      if (!request.params.message.includes("Allow Codex to use TestApp?")) {
        throw new Error(`unexpected elicitation message: ${request.params.message}`);
      }
      return { action: "accept", content: {} };
    });
  }
  await client.connect(transport);
  const res = await client.callTool({ name: tool, arguments: args });
  const text = (res.content ?? [])
    .filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("\n");
  await client.close();
  return { isError: !!res.isError, text };
}

const accepted = await run({ withElicitation: true });
console.log(`with elicitation support -> isError=${accepted.isError} text=${accepted.text}`);
if (accepted.isError || !accepted.text.includes("elicitation:accept")) {
  console.error("FAIL: elicitation was not forwarded to the client and accepted");
  process.exit(1);
}

const declined = await run({ withElicitation: false });
console.log(`without elicitation support -> isError=${declined.isError} text=${declined.text}`);
if (!declined.isError || !declined.text.includes("elicitation:decline")) {
  console.error("FAIL: expected fail-closed decline for a client without elicitation support");
  process.exit(1);
}

// Local perception tools (window enumeration, desktop capture) bypass the
// codex engine, so they must sit behind the same approval boundary.
const windowsDeclined = await run({ withElicitation: false, tool: "computer_windows", args: {} });
console.log(`computer_windows without elicitation support -> isError=${windowsDeclined.isError}`);
if (!windowsDeclined.isError || !windowsDeclined.text.includes("not approved")) {
  console.error("FAIL: expected fail-closed decline for local window enumeration");
  process.exit(1);
}

const shotDeclined = await run({ withElicitation: false, tool: "computer_screenshot", args: {} });
console.log(`desktop screenshot without elicitation support -> isError=${shotDeclined.isError}`);
if (!shotDeclined.isError || !shotDeclined.text.includes("not approved")) {
  console.error("FAIL: expected fail-closed decline for desktop capture");
  process.exit(1);
}

const openDeclined = await run({ withElicitation: false, tool: "computer_open", args: { app: "TestApp" } });
console.log(`computer_open without elicitation support -> isError=${openDeclined.isError}`);
if (!openDeclined.isError || !openDeclined.text.includes("not approved")) {
  console.error("FAIL: expected fail-closed decline for app launch");
  process.exit(1);
}

console.log("PASS: elicitation forwarding + fail-closed decline (engine and local capabilities)");
