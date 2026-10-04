# Remote Relay Authorization

Apply this rule to any PR that adds or changes v2 socket methods, adds or changes a path that forwards remote-host requests to the app (a relay policy or dispatch), edits the remote CLI command table (`daemon/remote/cmd/cmuxd-remote/commands.go`) or relay dispatch (`cli.go`, `cli_overrides.go`), or changes app-side handling of `initial_command` / `command` / `tmux_start_command` / `pane_start_command` params.

Background: GHSA-9vmv-3hjw-j28c. The `cmux ssh` reverse relay stores its credential on the remote host, so the remote host must be treated as a compromised client. The legacy app's `RemoteRelayCommandPolicy` (deleted with `CmuxRemoteWorkspace`) was the only authorization boundary between an authenticated relay client and command execution on the developer's Mac. The app in `Packages/macOS/CmuxNext` has no relay policy yet, so no relay path may reach its control socket until one exists. Any relay must deny by default; the allowlist, owned-target scoping, and command-parameter denial are the whole defense.

The same rule covers the cmux-tui daemon's **remote-relay entry** for paired servers (`ClientTransport::RemoteRelay`, the socket that only `cmux link` may connect to; plans/cmux-next/server-remote-conversations.md): its frame-level gate, its command allowlist, the `set-client-info` and `subscribe` reductions, the outbound writer filter and the remote-only serialization structs. A change there needs the same analysis and allow/deny tests. Apply this rule to changes in `cmux-tui/crates/cmux-tui-core/src/server.rs` (`handle_connection_message`, `ClientTransport`, `is_unix`, `require_local`), `cmux-tui/crates/cmux-tui-core/src/server/conversations.rs`, and the remote-origin tool gate (the daemon's PreToolUse hook decision and acpmux's permission step).

## Fail

- A relay path that reaches the app's control socket without a default-deny policy.
- A v2 method added to a relay allowlist (or a relay path that bypasses the policy) without a per-method security analysis in the PR description: does it execute commands or open content on local objects; can it mutate or destroy objects the remote session does not own; does it read local state.
- Allowlisting a method that spawns, respawns, or sends input to terminals where execution happens on the Mac. The legacy plain-SSH respawn path fell back to local execution under the same surface ID. "It targets an aliased surface" is not proof execution is remote.
- Any acceptance of `initial_command`, `command`, `tmux_start_command`, or `pane_start_command` through the relay, on any method, in any param position.
- A workspace/surface/tab ID param (for example `source_workspace_id`, `destination_surface_id`) that the policy does not scope to the remote session's owned objects.
- Weakening deny-by-default: prefix-allowing whole method families, accepting ref-form (non-UUID) IDs, or passing unmapped IDs through for convenience.
- Relay policy changes without tests covering both the allow and deny cases.
- Lowering the remote-origin approval minimum for any tool, permission mode or setting, or dropping or clearing the remote-origin mark of a running prompt chain.

## Pass

- Adding a v2 method that no relay allowlists, with no policy change.
- Allowlisting a method after the PR shows it cannot execute commands or mutate non-owned objects, with policy tests covering allow-with-owned-target and deny-with-unmapped-target / command-params.
- Extending ID scoping to a newly introduced param name, with a test proving it is enforced.
- Relay changes that keep the deny-by-default boundary intact and only adjust messaging, error shape, or test structure.

## Report

Name the exact method, param, and file. State which failure case applies (missing policy, unanalyzed allowlist addition, local-execution risk, unscoped ID param, command-param acceptance, weakened default-deny). Propose the minimal change that restores the boundary and name where the allow/deny tests belong.
