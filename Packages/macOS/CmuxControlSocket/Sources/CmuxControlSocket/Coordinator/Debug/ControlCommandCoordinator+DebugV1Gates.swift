#if DEBUG
internal import Foundation

/// The pure decision/payload halves of the v1-only drag-overlay gate and probe
/// commands (`overlay_drop_gate`, `sidebar_overlay_gate`,
/// `terminal_drop_overlay_probe`, `drop_hit_test`, `drag_hit_chain`).
///
/// Each method owns the token/coordinate parsing, the verbatim usage-error
/// strings, and the response formatting that the legacy
/// `TerminalController` v1 bodies built. The irreducible live-state reads stay
/// app-side behind the narrowed ``ControlDebugContext`` witnesses (which now
/// take already-parsed, typed inputs): `overlay_drop_gate`/
/// `sidebar_overlay_gate` evaluate `DragOverlayRoutingPolicy` against the live
/// `NSPasteboard(name: .drag)` types, `terminal_drop_overlay_probe` drives the
/// selected terminal panel's overlay animation, and `drop_hit_test`/
/// `drag_hit_chain` hit-test the live AppKit window. The
/// `overlay_hit_gate`/`portal_hit_gate` siblings keep their whole body in the
/// app target because their parse step maps to an AppKit `NSEvent.EventType`,
/// which `CmuxControlSocket` (an AppKit-free control-plane package) cannot host.
extension ControlCommandCoordinator {
    /// The v1 `overlay_drop_gate` body: parses `[external|local]` into the
    /// policy's `hasLocalDraggingSource` input (empty/`external` → `false`,
    /// `local` → `true`), reads the live policy through the seam, and returns
    /// `"true"`/`"false"`.
    ///
    /// - Parameter args: The raw `[external|local]` token.
    /// - Returns: `"true"`/`"false"`, or the verbatim usage `ERROR` line.
    func debugOverlayDropGateV1(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasLocalDraggingSource: Bool
        switch token {
        case "", "external":
            hasLocalDraggingSource = false
        case "local":
            hasLocalDraggingSource = true
        default:
            return "ERROR: Usage: overlay_drop_gate [external|local]"
        }
        let shouldCapture = debugContext?.controlDebugOverlayDropGate(
            hasLocalDraggingSource: hasLocalDraggingSource
        ) ?? false
        return shouldCapture ? "true" : "false"
    }

    /// The v1 `sidebar_overlay_gate` body: parses `[active|inactive]` into the
    /// policy's `hasSidebarDragState` input (empty/`active` → `true`,
    /// `inactive` → `false`), reads the live policy through the seam, and
    /// returns `"true"`/`"false"`.
    ///
    /// - Parameter args: The raw `[active|inactive]` token.
    /// - Returns: `"true"`/`"false"`, or the verbatim usage `ERROR` line.
    func debugSidebarOverlayGateV1(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSidebarDragState: Bool
        switch token {
        case "", "active":
            hasSidebarDragState = true
        case "inactive":
            hasSidebarDragState = false
        default:
            return "ERROR: Usage: sidebar_overlay_gate [active|inactive]"
        }
        let shouldCapture = debugContext?.controlDebugSidebarOverlayGate(
            hasSidebarDragState: hasSidebarDragState
        ) ?? false
        return shouldCapture ? "true" : "false"
    }

    /// The v1 `terminal_drop_overlay_probe` body: parses `[deferred|direct]`
    /// into the deferred-path flag (empty/`deferred` → deferred), runs the live
    /// probe through the seam, and reconstructs the legacy
    /// `"OK mode=… animated=… before=… after=… bounds=…x…"` line (with the
    /// `animated` flag derived from `after > before`).
    ///
    /// - Parameter args: The raw `[deferred|direct]` token.
    /// - Returns: The `OK …` line on success, or an `ERROR…` line (bad token or
    ///   an unavailable live precondition).
    func debugTerminalDropOverlayProbeV1(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let useDeferredPath: Bool
        switch token {
        case "", "deferred":
            useDeferredPath = true
        case "direct":
            useDeferredPath = false
        default:
            return "ERROR: Usage: terminal_drop_overlay_probe [deferred|direct]"
        }
        // An unwired context reads as `tabManagerUnavailable` — unreachable in
        // practice (the composition owner wires the context during init); it
        // reproduces the legacy `"ERROR: TabManager not available"` guard.
        let resolution = debugContext?.controlDebugTerminalDropOverlayProbe(
            useDeferredPath: useDeferredPath
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return "ERROR: TabManager not available"
        case .noWorkspace:
            return "ERROR: No selected workspace"
        case .noPanel:
            return "ERROR: No terminal panel available"
        case let .probed(before, after, boundsWidth, boundsHeight):
            let animated = after > before
            let mode = useDeferredPath ? "deferred" : "direct"
            return String(
                format: "OK mode=%@ animated=%d before=%d after=%d bounds=%.1fx%.1f",
                mode,
                animated ? 1 : 0,
                before,
                after,
                boundsWidth,
                boundsHeight
            )
        }
    }

    /// The v1 `drop_hit_test` body: parses and validates the `"<x 0-1> <y 0-1>"`
    /// argument line, then maps the normalized point to the live terminal
    /// surface under it through the seam.
    ///
    /// - Parameter args: The raw `"<x 0-1> <y 0-1>"` argument line.
    /// - Returns: A surface UUID, `"none"`, an `ERROR…` line from the live read,
    ///   or the verbatim usage `ERROR` line on a parse failure.
    func debugDropHitTestV1(_ args: String) -> String {
        guard let point = Self.parseNormalizedHitTestPoint(args) else {
            return "ERROR: Usage: drop_hit_test <x 0-1> <y 0-1>"
        }
        return debugContext?.controlDebugDropHitTest(nx: point.nx, ny: point.ny)
            ?? "ERROR: No window"
    }

    /// The v1 `drag_hit_chain` body: parses and validates the
    /// `"<x 0-1> <y 0-1>"` argument line, then returns the live AppKit hit-test
    /// view chain at the normalized point through the seam.
    ///
    /// - Parameter args: The raw `"<x 0-1> <y 0-1>"` argument line.
    /// - Returns: The `->`-joined chain, `"none"`, an `ERROR…` line from the
    ///   live read, or the verbatim usage `ERROR` line on a parse failure.
    func debugDragHitChainV1(_ args: String) -> String {
        guard let point = Self.parseNormalizedHitTestPoint(args) else {
            return "ERROR: Usage: drag_hit_chain <x 0-1> <y 0-1>"
        }
        return debugContext?.controlDebugDragHitChain(nx: point.nx, ny: point.ny)
            ?? "ERROR: No window"
    }

    /// Parses the shared `"<x 0-1> <y 0-1>"` argument line used by both
    /// `drop_hit_test` and `drag_hit_chain`: exactly two space-split fields,
    /// each a `Double` in the closed `0...1` range.
    ///
    /// - Parameter args: The raw argument line.
    /// - Returns: The normalized point, or `nil` when the line is malformed
    ///   (the caller turns `nil` into the command's usage `ERROR` line).
    private static func parseNormalizedHitTestPoint(_ args: String) -> (nx: Double, ny: Double)? {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let nx = Double(parts[0]), let ny = Double(parts[1]),
              (0...1).contains(nx), (0...1).contains(ny) else {
            return nil
        }
        return (nx, ny)
    }
}
#endif
