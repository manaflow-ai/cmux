# cmux computer use (MCP server)

`cmux-computer-use-mcp.mjs` is a dependency-free MCP stdio server that lets any
MCP agent cmux launches drive the local Mac through a cmux-owned macOS provider.

The tool surface is grounded in two signals:

- accessibility trees with short-lived element indices,
- screenshots returned as MCP image content.

The server keeps the latest snapshot table inside the MCP session. Element-index
actions are accepted only after the agent has received a fresh `computer_state`
snapshot for that app, and the snapshot is consumed by the first input action.

## Auto-attach in cmux

`Resources/bin/cmux-claude-wrapper` injects `--mcp-config` for Claude launches
inside live cmux terminals when all of these are true:

- `CMUX_COMPUTER_USE_MCP_DISABLED` is not `1`,
- the invocation did not request `--strict-mcp-config`,
- a trusted absolute `node` binary is available,
- the bundled `cmux-computer-use-mcp.mjs` resource exists.

No external agent runtime, login, or auth file is required.

## Permissions

The provider uses macOS Accessibility for UI trees and actions, and
`screencapture` / CGWindowList for screenshots and window metadata. macOS may
require Accessibility and Screen Recording permission for the host app or
terminal process running the MCP server.

The MCP server also asks the user before sharing or controlling an app:

- app inspection/control prompts are cached per app for the MCP session,
- full-desktop screenshot, window enumeration, and app launch each have their
  own prompt,
- clients without MCP elicitation support fail closed,
- headless automation can opt in with `CMUX_CU_AUTO_APPROVE=1`.

## Config

- `CMUX_CU_TIMEOUT_MS` — per-command timeout, default `180000`.
- `CMUX_CU_MAX_TREE` — max AX-tree characters returned by `computer_state`,
  default `60000`.
- `CMUX_CU_AUTO_APPROVE=1` — pre-approve app-control and local capability
  prompts for unattended runs.
- `CMUX_CU_FAKE_PROVIDER=1` — hermetic fake provider for tests; it does not
  touch the GUI.

## Tools

- `computer_target` — report the target machine and provider.
- `computer_apps` — list running controllable apps.
- `computer_open` — launch/focus an app (`open -a`).
- `computer_state` — primary perception: AX tree plus screenshot for an app.
- `computer_screenshot` — one app's window, or the full desktop with no `app`.
- `computer_click` — click by element index or screenshot x/y.
- `computer_type` — type text into the focused field.
- `computer_key` — key/chord such as `Return`, `Escape`, or `cmd+l`.
- `computer_scroll` — scroll an element by direction/pages.
- `computer_drag` — drag between screenshot coordinates.
- `computer_action` — invoke a named AX action on an element.
- `computer_windows` — CGWindowList dump as JSON, optionally filtered.

## Smoke tests

```bash
cd Resources/computer-use-mcp
npm install
npm test
node scripts/smoke.mjs
CMUX_CU_FAKE_PROVIDER=1 node scripts/smoke.mjs computer_state '{"app":"TestApp"}'
```

`npm test` is hermetic and uses the fake provider. Real app-state calls require
macOS permissions for the process hosting the MCP server.
