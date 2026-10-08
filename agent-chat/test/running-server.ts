// The manual e2e scripts talk to a server already running on this machine
// (`bun server.ts` or cmux-chat). Its route prefix is this launch's token,
// read from the owner-only state file the server wrote.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const statePath = process.env.CMUX_AGENT_CHAT_STATE_FILE || join(homedir(), ".cmux", "agent-chat", "state.json");
const state = JSON.parse(readFileSync(statePath, "utf8")) as { port: number; token: string };

export const PORT = state.port;
/// `ws://127.0.0.1:<port>/<token>/ws`.
export const WS_URL = `ws://127.0.0.1:${state.port}/${state.token}/ws`;
/// `http://127.0.0.1:<port>/<token>`, without a trailing slash.
export const HTTP_BASE = `http://127.0.0.1:${state.port}/${state.token}`;
