internal import Foundation

/// The v1 line-protocol debug/test command dispatch (`set_shortcut`,
/// `simulate_shortcut`, `activate_app`, the counter reads/resets, the panel
/// snapshot/screenshot family, and `debug_right_sidebar_focus`).
///
/// Every command here was compiled only into DEBUG builds (the legacy
/// `processCommand` cases sat inside `#if DEBUG`), so the whole dispatch is
/// `#if DEBUG`-gated: in release builds ``handleDebugV1`` returns `nil` and the
/// app's legacy v1 dispatcher falls through to its own `default:` exactly as
/// the compiled-out cases produced.
///
/// All but `debug_right_sidebar_focus` forward to the ``ControlDebugContext``
/// v1-shared witnesses, which run the still-app-resident v1 string bodies and
/// return their raw response verbatim — byte-identical to the legacy dispatch.
/// `debug_right_sidebar_focus` is reconstructed from the typed
/// ``ControlDebugRightSidebarFocusResolution`` (the same resolution the v2
/// `debug.right_sidebar.focus` consumes), reproducing the legacy flat-string
/// response with `focus_first_item` and the explicit window both unset, as the
/// legacy v1 body hardcoded.
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
