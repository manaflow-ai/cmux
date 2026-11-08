# Remote Relay Authorization

Apply this rule to any PR that adds or changes v2 socket methods, touches `RemoteRelayCommandPolicy.swift` or its tests, edits the remote CLI command table (`daemon/remote/cmd/cmuxd-remote/commands.go`) or relay dispatch (`cli.go`, `cli_overrides.go`), or changes app-side handling of `initial_command` / `command` / `tmux_start_command` / `pane_start_command` params.

Background: GHSA-9vmv-3hjw-j28c. The `cmux ssh` reverse relay stores its credential on the remote host, so the remote host must be treated as a compromised client. `RemoteRelayCommandPolicy` is the only authorization boundary between an authenticated relay client and arbitrary command execution on the developer's Mac. It denies by default; the allowlist, the owned-target scoping, and the command-parameter denial are the whole defense.

## Fail

- A v2 method added to the policy allowlist (or a relay path that bypasses the policy) without a per-method security analysis in the PR description: does it execute commands or open content on local objects; can it mutate or destroy objects the remote session does not own; does it read local state.
- Allowlisting a method that spawns, respawns, or sends input to terminals where execution happens on the Mac. The plain-SSH respawn path falls back to local execution under the same surface ID; `surface.respawn` is denied for this reason. "It targets an aliased surface" is not proof execution is remote.
- Any new acceptance of `initial_command`, `command`, `tmux_start_command`, or `pane_start_command` through the relay, on any method, in any param position.
- A new ID param name shaped like a workspace/surface/tab reference (for example `source_workspace_id`, `destination_surface_id`) that is not added to the policy's scoped key sets, leaving it unscoped.
- Weakening the policy's deny-by-default shape: prefix-allowing whole method families (other than the existing `browser.` and `workspace.group.` carve-outs), skipping the non-UUID (ref-form) denial, or passing unmapped IDs through for convenience.
- Changes to `RemoteRelayCommandPolicy.swift` or the session denial path without accompanying `RemoteCLIRelayPolicyTests` coverage for both the allow and deny cases.

## Pass

- Adding a v2 method that is simply not allowlisted (relay denies it; safe default) with no policy change.
- Allowlisting a method after the PR shows it cannot execute commands or mutate non-owned objects, with policy tests covering allow-with-owned-target and deny-with-unmapped-target / command-params.
- Extending the scoped key sets to cover a newly introduced ID param name, with a test proving the new key is enforced.
- Relay changes that keep the deny-by-default boundary intact and only adjust messaging, error shape, or test structure.

## Report

Name the exact method, param, and file. State which failure case applies (unanalyzed allowlist addition, local-execution risk, unscoped ID param, command-param acceptance, weakened default-deny). Propose the minimal change that restores the boundary, and name the test file where the allow/deny coverage belongs (`Packages/macOS/CmuxRemoteWorkspace/Tests/CmuxRemoteWorkspaceTests/RemoteCLIRelayPolicyTests.swift`).
