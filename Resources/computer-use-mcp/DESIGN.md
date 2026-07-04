# cmux computer use — design

Goal: expose a cmux-owned computer-use capability to any MCP agent launched from
cmux, without depending on another agent runtime.

## Architecture

`cmux-computer-use-mcp.mjs` is the MCP boundary and the session owner. It:

1. exposes the stable computer-use tools,
2. forwards approval requests to MCP elicitation,
3. captures app state through local macOS helpers,
4. stores the latest per-app snapshot table,
5. rejects stale element-index and coordinate actions.

The macOS provider path uses:

- `NSWorkspace` for running app discovery,
- Accessibility APIs for AX trees and semantic actions,
- `screencapture -C -l` for app-window screenshots with the native cursor,
- CGWindowList for window metadata,
- CoreGraphics events for coordinate click, drag, scroll, typing, and keys.

Element clicks move the macOS pointer to the element center before using
`AXPress`, so the cursor shown in the next screenshot still reflects the action
target even when the semantic accessibility action handled the click.

The implementation is currently a single bundled Node resource with embedded
Swift helper snippets. That keeps app-bundle wiring simple for this PR. If this
grows into a pane-visible runtime or long-lived helper, the next step is to
extract the provider into a dedicated cmux-owned helper binary with the same
JSON contract.

## Snapshot Contract

Element indices are scoped to the latest `computer_state` result for an app.
The server grants element-index actions only when:

- `computer_state` returned the table to the agent,
- the app matches the action,
- no input action has consumed that snapshot yet.

`computer_screenshot` grants coordinate actions but not element-index actions,
because the agent received pixels but not the fresh AX table.

## Safety Boundaries

The server asks before exposing or controlling an app. Approval is cached by
capability for the MCP session and fails closed when the client cannot elicit
user approval. MCP instructions still require the agent to stop and ask before
destructive, irreversible, or high-stakes actions.

The server filters child process environment variables before running helpers so
agent credentials and cmux socket credentials do not leak into native helper
processes.

## Test Strategy

The test path uses `CMUX_CU_FAKE_PROVIDER=1` to exercise MCP protocol behavior,
approval forwarding, queue bounds, cancellation cleanup, stale snapshot guards,
and localized approval prompts without touching the desktop.

Focused local checks:

```bash
node --check Resources/computer-use-mcp/cmux-computer-use-mcp.mjs
cd Resources/computer-use-mcp && npm test
python3 tests/test_claude_wrapper_hooks.py
```
