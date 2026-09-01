import AppKit
import WebKit

extension CmuxWebView {
    /// Find-family actions the diff viewer web app handles through the same
    /// navigation-action bridge as j/k scrolling. The diff app virtualizes its
    /// rows (off-screen lines are not in the DOM), so cmux's generic
    /// TreeWalker find cannot search it; the app implements find over its
    /// full diff model instead and cmux forwards the find shortcuts.
    enum DiffViewerFindAction: String {
        case open = "diffViewerOpenFind"
        case next = "diffViewerFindNext"
        case previous = "diffViewerFindPrevious"
        case close = "diffViewerCloseFind"
    }

    /// Whether the current document is a ready diff viewer app that owns
    /// find-in-page for this web view.
    var isDiffViewerFindOwner: Bool {
        diffViewerDocumentState.canHandleFindCommands
    }

    /// Forwards a find action to the diff viewer app. When the document is
    /// not a ready diff viewer, `fallback` runs synchronously (the generic
    /// browser find path). When the page later rejects the action, the
    /// renderer is marked unavailable and `fallback` runs then.
    func performDiffViewerFindAction(
        _ action: DiffViewerFindAction,
        fallback: @escaping @MainActor () -> Void
    ) {
        guard isDiffViewerFindOwner else {
#if DEBUG
            cmuxDebugLog(
                "diffViewer.find.fallback action=\(action.rawValue) " +
                    "state={\(diffViewerDocumentState.debugStateDescription)}"
            )
#endif
            fallback()
            return
        }
        let script = "window.__cmuxPerformDiffViewerNavigationAction?.('\(action.rawValue)') === true"
        evaluateJavaScript(script) { [weak self] result, error in
            guard error != nil || result as? Bool != true else { return }
            self?.diffViewerDocumentState.rendererDidBecomeUnavailable()
            fallback()
        }
    }

    func diffViewerFocusStateDidChange(viewer: Bool, editable: Bool, rendererReady: Bool) {
#if DEBUG
        cmuxDebugLog(
            "diffViewer.focusState viewer=\(viewer ? 1 : 0) editable=\(editable ? 1 : 0) " +
                "ready=\(rendererReady ? 1 : 0)"
        )
#endif
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
