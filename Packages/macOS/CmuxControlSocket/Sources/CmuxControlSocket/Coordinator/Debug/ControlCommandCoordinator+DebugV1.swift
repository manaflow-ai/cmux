internal import Foundation

/// The v1 line-protocol debug/test command dispatch (`set_shortcut`,
/// `simulate_shortcut`, `activate_app`, the counter reads/resets, the panel
/// snapshot/screenshot family, `debug_right_sidebar_focus`, and the v1-only
/// synthetic-input / drag-overlay probes `simulate_type`,
/// `simulate_file_drop`, the `seed_drag_pasteboard_*` family,
/// `clear_drag_pasteboard`, `drop_hit_test`, `drag_hit_chain`, and the
/// overlay/portal/sidebar gates).
///
/// Every command here was compiled only into DEBUG builds (the legacy
/// `processCommand` cases sat inside `#if DEBUG`), so the whole dispatch is
/// `#if DEBUG`-gated: in release builds ``handleDebugV1`` returns `nil` and the
/// app's legacy v1 dispatcher falls through to its own `default:` exactly as
/// the compiled-out cases produced.
///
/// Most commands forward to the ``ControlDebugContext`` witnesses, which run
/// the (still-app-resident, irreducibly AppKit/ghostty-coupled) v1 string
/// bodies and return their raw response verbatim — byte-identical to the legacy
/// dispatch. The `set_shortcut`/`simulate_shortcut`/`read_terminal_text`/… set
/// forward to v1-shared bodies that the v1 dispatcher still calls elsewhere;
/// the v1-only synthetic-input / drag-overlay probes have no v2 method, so
/// their witnesses carry the whole body. `debug_right_sidebar_focus` is
/// reconstructed from the typed ``ControlDebugRightSidebarFocusResolution`` (the
/// same resolution the v2 `debug.right_sidebar.focus` consumes), reproducing
/// the legacy flat-string response with `focus_first_item` and the explicit
/// window both unset, as the legacy v1 body hardcoded.
extension ControlCommandCoordinator {
    /// Dispatches the v1 debug/test commands this coordinator owns; returns
    /// `nil` for anything else (and unconditionally in release builds) so the
    /// app's legacy v1 dispatcher can fall through.
    ///
    /// - Parameters:
    ///   - command: The lowercased v1 command token.
    ///   - args: The raw argument remainder of the command line.
    /// - Returns: The raw reply line, or `nil` if not owned here.
    public func handleDebugV1(command: String, args: String) -> String? {
#if DEBUG
        switch command {
        case "set_shortcut":
            return debugContext?.controlDebugSetShortcut(arguments: args)
                ?? Self.debugContextUnavailableResponse
        case "simulate_shortcut":
            return debugContext?.controlDebugSimulateShortcut(combo: args)
                ?? Self.debugContextUnavailableResponse
        case "activate_app":
            return debugContext?.controlDebugActivateApp()
                ?? Self.debugContextUnavailableResponse
        case "is_terminal_focused":
            return debugContext?.controlDebugIsTerminalFocused(surfaceArgument: args)
                ?? Self.debugContextUnavailableResponse
        case "read_terminal_text":
            return debugContext?.controlDebugReadTerminalText(surfaceArgument: args)
                ?? Self.debugContextUnavailableResponse
        case "render_stats":
            return debugContext?.controlDebugRenderStats(surfaceArgument: args)
                ?? Self.debugContextUnavailableResponse
        case "layout_debug":
            return debugContext?.controlDebugLayout()
                ?? Self.debugContextUnavailableResponse
        case "bonsplit_underflow_count":
            return debugContext?.controlDebugBonsplitUnderflowCount()
                ?? Self.debugContextUnavailableResponse
        case "reset_bonsplit_underflow_count":
            return debugContext?.controlDebugResetBonsplitUnderflowCount()
                ?? Self.debugContextUnavailableResponse
        case "empty_panel_count":
            return debugContext?.controlDebugEmptyPanelCount()
                ?? Self.debugContextUnavailableResponse
        case "reset_empty_panel_count":
            return debugContext?.controlDebugResetEmptyPanelCount()
                ?? Self.debugContextUnavailableResponse
        case "focus_notification":
            return debugContext?.controlDebugFocusNotification(arguments: args)
                ?? Self.debugContextUnavailableResponse
        case "debug_right_sidebar_focus":
            return debugRightSidebarFocusV1(args)
        case "flash_count":
            return debugContext?.controlDebugFlashCount(surfaceArgument: args)
                ?? Self.debugContextUnavailableResponse
        case "reset_flash_counts":
            return debugContext?.controlDebugResetFlashCounts()
                ?? Self.debugContextUnavailableResponse
        case "panel_snapshot":
            return debugContext?.controlDebugPanelSnapshot(arguments: args)
                ?? Self.debugContextUnavailableResponse
        case "panel_snapshot_reset":
            return debugContext?.controlDebugPanelSnapshotReset(surfaceArgument: args)
                ?? Self.debugContextUnavailableResponse
        case "screenshot":
            return debugContext?.controlDebugCaptureScreenshot(label: args)
                ?? Self.debugContextUnavailableResponse
        case "simulate_type":
            return debugContext?.controlDebugSimulateType(arguments: args)
                ?? Self.debugContextUnavailableResponse
        case "simulate_file_drop":
            return debugContext?.controlDebugSimulateFileDrop(arguments: args)
                ?? Self.debugContextUnavailableResponse
        case "seed_drag_pasteboard_fileurl":
            return debugContext?.controlDebugSeedDragPasteboardTypes(arguments: "fileurl")
                ?? Self.debugContextUnavailableResponse
        case "seed_drag_pasteboard_tabtransfer":
            return debugContext?.controlDebugSeedDragPasteboardTypes(arguments: "tabtransfer")
                ?? Self.debugContextUnavailableResponse
        case "seed_drag_pasteboard_sidebar_reorder":
            return debugContext?.controlDebugSeedDragPasteboardTypes(arguments: "sidebarreorder")
                ?? Self.debugContextUnavailableResponse
        case "seed_drag_pasteboard_types":
            return debugContext?.controlDebugSeedDragPasteboardTypes(arguments: args)
                ?? Self.debugContextUnavailableResponse
        case "clear_drag_pasteboard":
            return debugContext?.controlDebugClearDragPasteboard()
                ?? Self.debugContextUnavailableResponse
        case "drop_hit_test":
            return debugDropHitTestV1(args)
        case "drag_hit_chain":
            return debugDragHitChainV1(args)
        case "overlay_hit_gate":
            return debugOverlayHitGateV1(args)
        case "overlay_drop_gate":
            return debugOverlayDropGateV1(args)
        case "portal_hit_gate":
            return debugPortalHitGateV1(args)
        case "sidebar_overlay_gate":
            return debugSidebarOverlayGateV1(args)
        case "terminal_drop_overlay_probe":
            return debugTerminalDropOverlayProbeV1(args)
        default:
            return nil
        }
#else
        return nil
#endif
    }

#if DEBUG
    /// The v1 `debug_right_sidebar_focus` body: trims the mode argument
    /// (empty → the app's `dock` default), reveals the right sidebar through the
    /// seam with `focusFirstItem: false` and no explicit window (both hardcoded
    /// in the legacy body), and reconstructs the flat-string response.
    ///
    /// - Parameter args: The raw mode-name argument.
    /// - Returns: `"OK: <details>"` on a successful reveal, or an `"ERROR:"`
    ///   line (invalid mode or a reveal that did not take).
    func debugRightSidebarFocusV1(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let modeName = trimmed.isEmpty ? nil : trimmed
        // An unwired context reads as `windowNotFound` — unreachable in
        // practice (the composition owner wires the context during init); the
        // legacy v1 body never reached this path.
        let resolution = debugContext?.controlDebugRightSidebarFocus(
            modeName: modeName,
            windowID: nil,
            focusFirstItem: false
        ) ?? .windowNotFound
        switch resolution {
        case .invalidMode(let name):
            return "ERROR: Invalid right sidebar mode: \(name)"
        case .windowNotFound:
            // The legacy v1 body passed no explicit window, so this case never
            // arose; surface it as a failed reveal to stay total.
            return "ERROR: mode= active= visible=0 context=0 state=0 focus=0"
        case .revealed(let state):
            let details = "mode=\(state.mode) active=\(state.activeMode ?? "") " +
                "visible=\(state.visible ? 1 : 0) " +
                "context=\(state.contextFound ? 1 : 0) state=\(state.stateFound ? 1 : 0) " +
                "focus=\(state.focusApplied ? 1 : 0)"
            return state.revealed ? "OK: \(details)" : "ERROR: \(details)"
        }
    }
#endif
}
