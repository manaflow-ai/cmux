internal import Foundation

/// The debug/test-only domain (`debug.*` main-actor methods), lifted
/// byte-faithfully from the former `TerminalController.v2Debug*` bodies. Each
/// payload is built directly as a ``JSONValue``; the encoded wire bytes match.
///
/// This domain is DEBUG-gated end to end; release builds fall through to the
/// same `method_not_found` behavior as the former compiled-out cases. The worker-lane
/// `debug.sidebar.simulate_drag` and the shared `debug.terminals` stay
/// app-side/surface-domain and are NOT handled here.
///
/// This file carries the dispatch plus the session-snapshot, shortcut, input,
/// text-box, and command-palette methods; the rest live in `+Debug2.swift`
/// (500-line budget).
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the debug domain, returning
    /// the typed result; returns `nil` otherwise so the caller can fall
    /// through. The integrator calls this from the core `handle`.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a debug method (or in a
    ///   release build, where the domain does not exist).
    func handleDebug(_ request: ControlRequest) -> ControlCallResult? {
#if DEBUG
        switch request.method {
        case "remote.tmux.sizing_settled":
            return debugRemoteTmuxSizingSettled()
        case "debug.session_snapshot_benchmark":
            return debugSessionSnapshotBenchmark(request.params)
        case "debug.session_snapshot_seed_scrollback":
            return debugSessionSnapshotSeedScrollback(request.params)
        case "debug.process_metrics.read":
            return debugProcessMetricsRead()
        case "debug.process_metrics.reset":
            return debugProcessMetricsReset()
        case "debug.shortcut.set":
            return debugShortcutSet(request.params)
        case "debug.shortcut.simulate":
            return debugShortcutSimulate(request.params)
        case "debug.type":
            return debugType(request.params)
        case "debug.textbox.inline_fixture":
            return debugTextBoxInlineFixture(request.params)
        case "debug.textbox.interact":
            return debugTextBoxInteract(request.params)
        case "debug.app.activate":
            return debugActivateApp()
        case "debug.workspace_todo.checklist_add_field":
            return debugWorkspaceTodoChecklistAddField()
        case "debug.pro_welcome_checklist.show":
            return debugShowProWelcomeChecklist()
        case "debug.command_palette.toggle":
            return debugCommandPaletteEvent(.toggle, request.params)
        case "debug.command_palette.rename_tab.open":
            return debugCommandPaletteEvent(.renameTabOpen, request.params)
        case "debug.command_palette.visible":
            return debugCommandPaletteVisible(request.params)
        case "debug.command_palette.selection":
            return debugCommandPaletteSelection(request.params)
        case "debug.command_palette.results":
            return debugCommandPaletteResults(request.params)
        case "debug.command_palette.rename_input.interact":
            return debugCommandPaletteEvent(.renameInputInteraction, request.params)
        case "debug.command_palette.rename_input.delete_backward":
            return debugCommandPaletteEvent(.renameInputDeleteBackward, request.params)
        case "debug.command_palette.rename_input.selection":
            return debugCommandPaletteRenameInputSelection(request.params)
        case "debug.command_palette.rename_input.select_all":
            return debugCommandPaletteRenameInputSelectAll(request.params)
        case "debug.browser.address_bar_focused":
            return debugBrowserAddressBarFocused(request.params)
        case "debug.browser.favicon":
            return debugBrowserFavicon(request.params)
        case "debug.right_sidebar.focus":
            return debugRightSidebarFocus(request.params)
        case "debug.sidebar.visible":
            return debugSidebarVisible(request.params)
        case "debug.terminal.is_focused":
            return debugIsTerminalFocused(request.params)
        case "debug.terminal.simulate_file_drop":
            return debugSimulateTerminalFileDrop(request.params)
        case "debug.terminal.read_text":
            return debugReadTerminalText(request.params)
        case "debug.terminal.render_stats":
            return debugRenderStats(request.params)
        case "debug.layout":
            return debugLayout()
        case "debug.portal.stats":
            return debugPortalStats()
        case "debug.bonsplit_underflow.count":
            return debugBonsplitUnderflowCount()
        case "debug.bonsplit_underflow.reset":
            return debugResetBonsplitUnderflowCount()
        case "debug.empty_panel.count":
            return debugEmptyPanelCount()
        case "debug.empty_panel.reset":
            return debugResetEmptyPanelCount()
        case "debug.notification.focus":
            return debugFocusNotification(request.params)
        case "debug.flash.count":
            return debugFlashCount(request.params)
        case "debug.flash.reset":
            return debugResetFlashCounts()
        case "debug.panel_snapshot":
            return debugPanelSnapshot(request.params)
        case "debug.panel_snapshot.reset":
            return debugPanelSnapshotReset(request.params)
        case "debug.window.screenshot":
            return debugScreenshot(request.params)
        case "debug.canvas.command_scroll_hint":
            return debugCanvasCommandScrollHint(request.params)
        default:
            return nil
        }
#else
        return nil
#endif
    }
}
