#if DEBUG
internal import Foundation

/// The pure decision/payload halves of the v1-only drag-overlay gate and probe
/// commands (`overlay_drop_gate`, `sidebar_overlay_gate`, `overlay_hit_gate`,
/// `portal_hit_gate`, `terminal_drop_overlay_probe`, `drop_hit_test`,
/// `drag_hit_chain`).
///
/// Each method owns the token/coordinate parsing, the verbatim usage-error
/// strings, and the response formatting that the legacy
/// `TerminalController` v1 bodies built. The irreducible live-state reads stay
/// app-side behind the narrowed ``ControlDebugContext`` witnesses (which now
/// take already-parsed, typed inputs): `overlay_drop_gate`/
/// `sidebar_overlay_gate`/`overlay_hit_gate`/`portal_hit_gate` evaluate
/// `DragOverlayRoutingPolicy` against the live `NSPasteboard(name: .drag)`
/// types, `terminal_drop_overlay_probe` drives the selected terminal panel's
/// overlay animation, and `drop_hit_test`/`drag_hit_chain` hit-test the live
/// AppKit window. The `overlay_hit_gate`/`portal_hit_gate` event-type token
/// reaches the seam as an AppKit-free ``ControlDebugOverlayEventToken``; only
/// the `NSEvent.EventType` mapping stays app-side, because `CmuxControlSocket`
/// (an AppKit-free control-plane package) cannot host the AppKit event type.
extension ControlCommandCoordinator {
    /// The shared usage `ERROR` line for the two event-type gate commands,
    /// parameterized by command name so each reproduces its legacy verbatim
    /// `"ERROR: Usage: <name> <…event types…>"` string exactly.
    ///
    /// - Parameter command: The command name (`overlay_hit_gate` /
    ///   `portal_hit_gate`).
    /// - Returns: The verbatim usage `ERROR` line.
    private static func overlayEventGateUsage(_ command: String) -> String {
        "ERROR: Usage: \(command) <leftMouseDragged|rightMouseDragged|otherMouseDragged|mouseMoved|mouseEntered|mouseExited|flagsChanged|cursorUpdate|appKitDefined|systemDefined|applicationDefined|periodic|leftMouseDown|leftMouseUp|rightMouseDown|rightMouseUp|otherMouseDown|otherMouseUp|scrollWheel|none>"
    }

    /// The outcome of parsing the shared event-type token argument: either a
    /// recognized token, or the verbatim `ERROR` line the command must return.
    private enum OverlayEventGateParse {
        case token(ControlDebugOverlayEventToken)
        case error(String)
    }

    /// Parses the shared event-type token argument for the two gate commands:
    /// trims/lowercases the raw argument, rejects an empty token with the
    /// command's usage `ERROR` line, and rejects an unrecognized token with the
    /// legacy `"ERROR: Unknown event type '…'"` line (echoing the trimmed,
    /// original-case argument).
    ///
    /// - Parameters:
    ///   - args: The raw event-type argument.
    ///   - command: The command name, for the usage `ERROR` line.
    /// - Returns: The recognized token on success, or the verbatim `ERROR` line
    ///   to return on a parse failure.
    private static func parseOverlayEventGateToken(
        _ args: String,
        command: String
    ) -> OverlayEventGateParse {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed.lowercased()
        guard !token.isEmpty else {
            return .error(overlayEventGateUsage(command))
        }
        guard let parsed = ControlDebugOverlayEventToken(lowercasedToken: token) else {
            return .error("ERROR: Unknown event type '\(trimmed)'")
        }
        return .token(parsed)
    }

    /// The v1 `overlay_hit_gate` body: parses the event-type token (owning the
    /// usage/unknown `ERROR` strings), evaluates the live file-drop overlay
    /// hit-capture policy through the seam, and returns `"true"`/`"false"`.
    ///
    /// - Parameter args: The raw event-type token argument.
    /// - Returns: `"true"`/`"false"`, or a verbatim `ERROR` line on a parse
    ///   failure.
    func debugOverlayHitGateV1(_ args: String) -> String {
        switch Self.parseOverlayEventGateToken(args, command: "overlay_hit_gate") {
        case .error(let errorLine):
            return errorLine
        case .token(let token):
            let shouldCapture = debugContext?.controlDebugOverlayHitGate(
                eventToken: token
            ) ?? false
            return shouldCapture ? "true" : "false"
        }
    }

    /// The v1 `portal_hit_gate` body: parses the event-type token (owning the
    /// usage/unknown `ERROR` strings), evaluates the live terminal-portal
    /// hit-pass-through policy through the seam, and returns `"true"`/`"false"`.
    ///
    /// - Parameter args: The raw event-type token argument.
    /// - Returns: `"true"`/`"false"`, or a verbatim `ERROR` line on a parse
    ///   failure.
    func debugPortalHitGateV1(_ args: String) -> String {
        switch Self.parseOverlayEventGateToken(args, command: "portal_hit_gate") {
        case .error(let errorLine):
            return errorLine
        case .token(let token):
            let shouldPassThrough = debugContext?.controlDebugPortalHitGate(
                eventToken: token
            ) ?? false
            return shouldPassThrough ? "true" : "false"
        }
    }

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
