import AppKit
import CmuxTerminal

/// Conforms the app-target ``TerminalPanel`` to the focused-terminal command
/// seam ``FocusedTerminalCommanding`` driven by
/// ``FocusedTerminalCommandCoordinator`` in CmuxTerminal.
///
/// The panel owns the AppKit hosted view, the panel-level `searchState`, the
/// focus-intent plumbing, and the app-target find notification names, none of
/// which can move into the package. These witnesses are byte-faithful lifts of
/// the former `TabManager.startSearch()`, `searchSelection()`, `findNext()`,
/// `findPrevious()`, `hideFind()`, `toggleFocusedTerminalCopyMode()`,
/// `sendCtrlFToFocusedTerminal()`, and `clearFocusedTerminalKeepingScrollback()`
/// bodies (the terminal-panel branch of each), with the workspace-level routing
/// and browser fallback left to the coordinator. The text-box witnesses
/// (`toggleTextBoxInput()`, `focusTextBoxInputOrTerminal()`,
/// `attachFileToTextBoxInput()`, `consumeTextBoxHideEscapeIfArmed(in:)`,
/// `clearTextBoxHideEscapeArm()`) are satisfied directly by `TerminalPanel`'s
/// existing methods.
extension TerminalPanel: FocusedTerminalCommanding {
    var isSearchVisible: Bool {
        searchState != nil
    }

    var hasSelectionForFind: Bool {
        hasSelection() == true
    }

    @discardableResult
    func startSearch() -> Bool {
        let hadExistingSearch = searchState != nil
        hostedView.preparePanelFocusIntentForActivation(.findField)
        let recoveredNeedle = hadExistingSearch ? "" : surface.lastSearchNeedle
        let handled = surface.startOrFocusSearch(initialNeedle: recoveredNeedle) { surface in
            NotificationCenter.default.post(
                name: .ghosttySearchFocus,
                object: surface,
                userInfo: [FindFocusNotificationKey.selectAll: !hadExistingSearch && !recoveredNeedle.isEmpty]
            )
        }
#if DEBUG
        cmuxDebugLog(
            "find.startSearch workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(id.uuidString.prefix(5)) existing=\(hadExistingSearch ? "yes" : "no") " +
            "handled=\(handled ? 1 : 0) " +
            "firstResponder=\(String(describing: surface.uiWindow?.firstResponder))"
        )
#endif
        return handled
    }

    func searchSelection() {
        if searchState == nil {
            searchState = TerminalSurface.SearchState()
        }
#if DEBUG
        cmuxDebugLog(
            "find.searchSelection workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(id.uuidString.prefix(5))"
        )
#endif
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: surface)
        _ = performBindingAction("search_selection")
    }

    func findNext() {
        _ = performBindingAction("search:next")
    }

    func findPrevious() {
        _ = performBindingAction("search:previous")
    }

    func hideSearch() {
        searchState = nil
    }

    @discardableResult
    func toggleKeyboardCopyMode() -> Bool {
        surface.toggleKeyboardCopyMode()
    }

    @discardableResult
    func sendCtrlF() -> Bool {
        let result = sendNamedKeyResult("ctrl-f")
        if result == .sent {
            surface.forceRefresh(reason: "tabManager.sendCtrlFToFocusedTerminal")
        }
#if DEBUG
        cmuxDebugLog(
            "terminal.sendCtrlF workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(id.uuidString.prefix(5)) result=\(result)"
        )
#endif
        return result.accepted
    }

    @discardableResult
    func clearScreenKeepingScrollbackAndRefresh() -> Bool {
        let cleared = clearScreenKeepingScrollback()
        if cleared {
            surface.forceRefresh(reason: "tabManager.clearFocusedTerminalKeepingScrollback")
        }
        return cleared
    }
}
