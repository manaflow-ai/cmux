# CMUX Surface Status sidebar

Surface Status is a companion app with an embedded `CmuxExtensionKit` sidebar. It does not patch `/Applications/cmux.app`.

## Runtime architecture

The product has three small responsibilities:

1. Display workspace, surface, and per-surface agent lifecycle state.
2. Optionally install receipt-owned, content-free Pi and OpenCode status adapters.
3. Optionally install a launch-only Codex helper so a new Codex process is identified before its first prompt.

Claude and Codex lifecycle state remains owned by cmux's native integrations. Surface Status reads native lifecycle metadata but never changes official Codex hooks, trust, configuration, session data, Feed behavior, resume/fork behavior, notifications, or remote/iOS behavior.

### Pi and OpenCode

Canonical payloads are bundled under:

```text
Apps/SurfaceStatus/SurfaceStatusApp/AdapterPayloads/
```

They publish lifecycle metadata only: agent ID, surface/workspace IDs, state, reason, PID, owner token, and timestamp. They do not publish prompts, responses, tool input/output, commands, or environment secrets.

The companion app owns installation, disable, enable, update, and uninstall. It records exact paths and hashes under:

```text
~/.local/state/cmux/surface-status-adapters/
```

Modified or unmanaged files are preserved and reported instead of overwritten.

### Claude

No Claude adapter is installed. The sidebar reads cmux's native lifecycle store.

### Codex

Official cmux persistent hooks and `~/.cmuxterm/codex-hook-sessions.json` are authoritative. The optional shell helper writes only a provisional, process-bound launch marker. A marker may show Codex Idle before the first native event; it cannot synthesize Working, Done, Needs Input, Error, approvals, or tool lifecycle.

The Sidebar rejects malformed UUIDs, dead/reused PIDs, unsafe timestamps, and invalid active owners. Native lifecycle always overrides the launch marker. Ordinary uninstall removes only the receipt-owned helper and exact `.zshrc` source block; official Codex files remain untouched.

## Development

Build and install the companion app without rebuilding cmux:

```bash
scripts/deploy-surface-status-sidebar.sh \
  --clean \
  --refresh \
  --install-dir "$HOME/Applications"
```

Package a local-test DMG:

```bash
scripts/package-surface-status-sidebar.sh --skip-notarize
```

Public distribution additionally requires Developer ID signing and notarization.

Run focused payload tests:

```bash
node \
  Apps/SurfaceStatus/AdapterPayloadTests/run-pi-sidebar-agent-status-test.mjs
node --test \
  Apps/SurfaceStatus/AdapterPayloadTests/opencode-sidebar-agent-status.test.mjs
```

Run the companion Xcode test scheme for manager and Codex projection coverage.

## Removing Surface Status

1. In cmux, choose another sidebar provider and disable Surface Status.
2. In the companion app, uninstall the receipt-owned integrations if desired.
3. Quit and remove `CMUX Surface Status Sidebar.app`.

No migration or prototype-cleanup tools ship with the product. Historical developer prototypes were unreleased; their one-time cleanup scripts and hard-coded legacy hashes were intentionally removed rather than carried as permanent maintenance surface.
