import AppKit

extension CmuxWebView {
    /// Executes a viewer action whose leader was consumed by the global prefix
    /// monitor before this WebKit view could observe it.
    @discardableResult
    func performResolvedDiffViewerNavigation(
        _ action: KeyboardShortcutSettings.Action,
        event: NSEvent
    ) -> Bool {
        guard cmuxOwnsKeyEvent(event),
              diffViewerDocumentState.canHandleNavigation else {
            diffViewerNavigationKeyRouter.reset()
            return false
        }
        return diffViewerNavigationKeyRouter.performResolved(
            action,
            event: event,
            isAllowed: { action, event in
                AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: event) ?? true
            },
            perform: { [weak self] action in
                self?.performDiffViewerNavigationAction(action)
            }
        )
    }

    private func performDiffViewerNavigationAction(_ action: KeyboardShortcutSettings.Action) {
        let rawAction = action.rawValue.replacingOccurrences(of: "'", with: "\\'")
        let script = "window.__cmuxPerformDiffViewerNavigationAction?.('\(rawAction)') === true"
        if action == .diffViewerOpenFileSearch {
            diffViewerDocumentState.beginEditableFocusTransition()
        }
        evaluateJavaScript(script) { [weak self] result, error in
            guard error != nil || result as? Bool != true else { return }
            if action == .diffViewerOpenFileSearch {
                self?.diffViewerDocumentState.editableFocusTransitionDidFail()
            }
            self?.diffViewerDocumentState.rendererDidBecomeUnavailable()
        }
    }
}
