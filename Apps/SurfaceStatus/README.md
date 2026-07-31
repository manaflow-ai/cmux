# CMUX Surface Status companion app

This standalone macOS app embeds the Surface Status ExtensionKit sidebar and a native management UI for optional Pi and OpenCode lifecycle adapters. End users do not need a cloned cmux repository.

The management app supports install, refresh, disable, enable, and uninstall for receipt-owned Pi/OpenCode adapters plus a launch-only Codex attribution helper. It preserves Herdr, cmux-native hooks, agent sessions, and unrelated plugins. Claude and Codex continue to use cmux's native lifecycle stores; the companion never installs, disables, or uninstalls their hooks.

For Codex, cmux's official persistent hooks remain the sole lifecycle authority and sole writer of `~/.cmuxterm/codex-hook-sessions.json`. The optional shell helper publishes only a content-free, process-bound Idle marker during the pre-prompt startup window. Official native lifecycle always overrides it. Dead or reused PIDs are ignored, and ordinary helper uninstall preserves native hooks and sessions.

The product app contains no session-restore logic. If an unmanaged or edited Pi/OpenCode adapter exists at a managed path, installation or removal fails closed. Adapter uninstall and extension removal are separate: select another sidebar in cmux, optionally uninstall the receipt-owned Pi/OpenCode adapters, quit the companion, and move `CMUX Surface Status Sidebar.app` to Trash.

The containing app is intentionally non-sandboxed for explicit user-initiated writes to Pi and OpenCode plugin directories. The embedded sidebar extension remains sandboxed with read-only access to lifecycle stores.

## Development

```bash
scripts/deploy-surface-status-sidebar.sh --clean --refresh --install-dir "$HOME/Applications"
scripts/package-surface-status-sidebar.sh --skip-notarize
node Apps/SurfaceStatus/AdapterPayloadTests/run-pi-sidebar-agent-status-test.mjs
node --test Apps/SurfaceStatus/AdapterPayloadTests/opencode-sidebar-agent-status.test.mjs
```

`AdapterPayloads/` is the single source of truth for shipped Pi, OpenCode, and Codex helper payloads. Generated DMGs and one-time prototype migration/reset tools are intentionally not kept in the repository.
