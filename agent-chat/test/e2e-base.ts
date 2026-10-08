// The base URL of a running dev server for the manual e2e scripts: every
// route but /healthz is under the server's per-launch token, read from
// CMUX_AGENT_CHAT_TOKEN or the server's owner-only token file.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const E2E_PORT = Number(process.env.CMUX_AGENT_UI_PORT ?? 7739);

export function e2eToken(): string {
  const given = process.env.CMUX_AGENT_CHAT_TOKEN;
  if (given) return given;
  const file = process.env.CMUX_AGENT_CHAT_TOKEN_FILE || join(homedir(), ".cmux", "agent-chat", `token-${E2E_PORT}`);
  return readFileSync(file, "utf8").trim();
}

export const E2E_HTTP = `http://127.0.0.1:${E2E_PORT}/${e2eToken()}`;
export const E2E_WS = `ws://127.0.0.1:${E2E_PORT}/${e2eToken()}/ws`;
