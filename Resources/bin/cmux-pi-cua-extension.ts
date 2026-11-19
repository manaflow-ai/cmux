// Loaded only by cmux-pi-wrapper after it verifies a live cmux surface, the
// app-installed helper and a private socket credential. Nothing is persisted
// to Pi's user or project MCP configuration.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  const client = process.env.CMUX_PI_CUA_CLIENT;
  const socket = process.env.CMUX_PI_CUA_SOCKET;
  const session = process.env.CMUX_PI_CUA_SESSION;
  const stateDir = process.env.CMUX_PI_CUA_STATE_DIR;
  const token = process.env.CMUX_CUA_SOCKET_AUTH_TOKEN;
  if (!client || !socket || !session || !stateDir || !token) return;

  pi.registerMcpServer("cmux-cua", {
    command: client,
    args: ["mcp", "--socket", socket],
    exposure: "deferred",
    description: "cmux Computer Use; invoke only after an explicit user request.",
    env: {
      CMUX_CUA_SOCKET_AUTH_TOKEN: token,
      CMUX_CUA_MCP_FORCE_PROXY: "1",
      CMUX_CUA_EXTERNAL_PERMISSION_FLOW: "1",
      CMUX_CUA_DEFAULT_SESSION: session,
      CMUX_CUA_STATE_OWNER_PID: String(process.pid),
      CMUX_CUA_STATE_DIR: stateDir,
      CMUX_CUA_TELEMETRY_ENABLED: "false",
      CMUX_CUA_UPDATE_CHECK: "false",
      NODE_OPTIONS: "",
      BUN_OPTIONS: "",
    },
  });
}
