# CmuxTerminalCore

The terminal domain's core leaf: pure and Sendable terminal logic with no view dependency, lifted out of the app target's `GhosttyTerminalView.swift`. Higher terminal packages (engine, surface model, surface views) and the app depend on this; it depends only on GhosttyKit, `CmuxTerminalCopyMode`, and the DEBUG-only event log.

## Layout

- `Interop/` — `GhosttyRuntimeCInterop`, the one sanctioned seam for `@_silgen_name` libghostty bindings.
- `KeyEvents/` — `ghostty_input_action_e.modifierActionForFlagsChanged` (flagsChanged press/release resolution) and the `NSEvent.ModifierFlags` adapter for `CmuxTerminalCopyMode`.
- `PathResolution/` — `TerminalPathResolver`, the path heuristics behind cmd-click QuickLook and terminal file-link opening.
- `LinkRouting/` — `TerminalLinkRouter` and `TerminalOpenURLTarget`, routing terminal links to the embedded browser or the system through the `BrowserHostNormalizing` seam.
- `SurfaceCallbacks/` — `GhosttySurfaceCallbackContext`, the retained userdata for libghostty callbacks, behind the `TerminalSurfaceControlling`/`TerminalSurfaceHosting` seams.
- `SurfaceValues/` — the Sendable surface value DTOs (`PendingKeyEvent`, `PendingSocketInput`, `ParsedSocketInput`, `NamedKeySendResult`, `InputSendResult`, `PortalLifecycleState`, `PortalHostLease`).
- `Scrollbar/` — `GhosttyScrollbar`, the runtime scrollback geometry snapshot.
- `DebugSupport/` — DEBUG-only UI-test scaffolding (`TerminalChildExitProbe`, scalar-hex journaling).

## Seams

Protocols are owned here and implemented in the app target: `BrowserHostNormalizing` (browser-domain host validation for link routing) and `TerminalSurfaceControlling`/`TerminalSurfaceHosting` (the surface model and host view sides of the runtime callback context). The app injects conformances at the composition root; this package never imports the app or the browser domain.

## Testing

All logic is pure or probe-injectable, so tests run headlessly with `swift test`. The path resolver takes a `fileExists` closure, the link router takes a stub `BrowserHostNormalizing`, and the callback context takes plain test doubles of its two seams.
