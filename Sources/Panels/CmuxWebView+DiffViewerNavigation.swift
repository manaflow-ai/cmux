import AppKit
import WebKit

extension CmuxWebView {
    func diffViewerFocusStateDidChange(viewer: Bool, editable: Bool, rendererReady: Bool) {
        diffViewerDocumentState.update(viewer: viewer, editable: editable, rendererReady: rendererReady)
        if !viewer || editable {
            diffViewerNavigationKeyRouter.reset()
        }
    }

    func diffViewerNavigationDidStart(_ navigation: WKNavigation?) {
        diffViewerDocumentState.navigationDidStart(id: navigation.map(ObjectIdentifier.init))
        diffViewerNavigationKeyRouter.reset()
    }

    func diffViewerNavigationDidCommit(_ navigation: WKNavigation?) {
        diffViewerDocumentState.navigationDidCommit(id: navigation.map(ObjectIdentifier.init))
    }

    func diffViewerNavigationDidCancel(_ navigation: WKNavigation?) {
        diffViewerDocumentState.navigationDidCancel(id: navigation.map(ObjectIdentifier.init))
    }

    func handleDiffViewerNavigationKey(_ event: NSEvent) -> Bool {
        guard cmuxOwnsKeyEvent(event),
              diffViewerDocumentState.canHandleNavigation else {
            diffViewerNavigationKeyRouter.reset()
            return false
        }
        return diffViewerNavigationKeyRouter.handle(event, isAllowed: { action, event in
            AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: event) ?? true
        }, perform: { [weak self] action in
            self?.performDiffViewerNavigationAction(action)
        })
    }

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
