import CmuxTerminal
import Foundation

extension TabManager {
    var isFindVisible: Bool {
        selectedTerminalPanel?.searchState != nil ||
            focusedMarkdownPanelForFind?.isFindVisible == true ||
            focusedBrowserPanel?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedTerminalPanel?.hasSelection() == true ||
            focusedMarkdownPanelForFind?.canUseSelectionForFind == true
    }

    @discardableResult
    func startSearch() -> Bool {
        if let panel = selectedTerminalPanel {
            let hadExistingSearch = panel.searchState != nil
            panel.hostedView.preparePanelFocusIntentForActivation(.findField)
            let recoveredNeedle = hadExistingSearch ? "" : panel.surface.lastSearchNeedle
            let handled = startOrFocusTerminalSearch(panel.surface, initialNeedle: recoveredNeedle) { surface in
                NotificationCenter.default.post(
                    name: .ghosttySearchFocus,
                    object: surface,
                    userInfo: [FindFocusNotificationKey.selectAll: !hadExistingSearch && !recoveredNeedle.isEmpty]
                )
            }
#if DEBUG
            cmuxDebugLog(
                "find.startSearch workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
                "panel=\(panel.id.uuidString.prefix(5)) existing=\(hadExistingSearch ? "yes" : "no") " +
                "handled=\(handled ? 1 : 0) " +
                "firstResponder=\(String(describing: panel.surface.uiWindow?.firstResponder))"
            )
#endif
            return handled
        }
        if let markdownPanel = focusedMarkdownPanelForFind {
            return markdownPanel.startFind()
        }
        guard let browserPanel = focusedBrowserPanel else { return false }
        browserPanel.startFind()
        return browserPanel.searchState != nil
    }

    func searchSelection() {
        if focusedMarkdownPanelForFind?.searchSelection() == true {
            return
        }

        guard let panel = selectedTerminalPanel else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
#if DEBUG
        cmuxDebugLog(
            "find.searchSelection workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
            "panel=\(panel.id.uuidString.prefix(5))"
        )
#endif
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("search_selection")
    }

    func findNext() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:next")
            return
        }

        if focusedMarkdownPanelForFind?.findNext() == true {
            return
        }

        focusedBrowserPanel?.findNext()
    }

    func findPrevious() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:previous")
            return
        }

        if focusedMarkdownPanelForFind?.findPrevious() == true {
            return
        }

        focusedBrowserPanel?.findPrevious()
    }

    /// Returns the focused Markdown panel for native find actions. Unlike
    /// preview zoom, Find is valid in both the rendered preview and raw text
    /// editor modes.
    ///
    /// A main-area or Dock browser can own the AppKit first responder while the
    /// workspace's `focusedPanelId` still points at a Markdown panel (Dock focus
    /// does not rewrite `focusedPanelId`). Because every find router consults
    /// this property before `focusedBrowserPanel`, returning the Markdown panel
    /// in that state would steal Cmd+F / Cmd+G / Cmd+E / Hide Find from the
    /// browser the user is actually in. `focusedBrowserPanel` is first-responder
    /// aware, so defer to it whenever it resolves a browser. When no browser
    /// owns focus it is nil here — its only non-first-responder path is a
    /// `focusedPanelId`-based browser, which is mutually exclusive with this
    /// Markdown match — so this still returns the Markdown panel in the normal
    /// case (and in the raw-text editor, which cannot coexist with browser
    /// first-responder ownership).
    var focusedMarkdownPanelForFind: MarkdownPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let markdownPanel = tab.panels[panelId] as? MarkdownPanel else { return nil }
        if focusedBrowserPanel != nil { return nil }
        return markdownPanel
    }
}
