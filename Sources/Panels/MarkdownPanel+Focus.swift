import AppKit
import CmuxBrowser
import Foundation

extension MarkdownPanel {
    // MARK: - Find in preview focus

    /// Shows (or refocuses) the preview find bar. Preview-only: text mode uses
    /// the NSTextView's native find panel via the responder chain.
    func startFind() {
        guard displayMode == .preview else { return }
        let created = searchState == nil
        let recoveredNeedle = created ? lastSearchNeedle : ""
        if created { searchState = BrowserSearchState(needle: recoveredNeedle) }
        let shouldSelectAll = created && !recoveredNeedle.isEmpty
        searchFocusRequestGeneration &+= 1
        let generation = searchFocusRequestGeneration
        activeSearchFocusRequestGeneration = generation
        postSearchFocusNotification(generation: generation, selectAll: shouldSelectAll)
        // Re-post once because the overlay mounts on the same runloop turn and
        // can miss the first notification.
        DispatchQueue.main.async { [weak self] in
            self?.postSearchFocusNotification(generation: generation, selectAll: shouldSelectAll)
        }
    }

    /// Hides the preview find bar without changing focus owned by its document.
    func hideFind() {
        guard let searchState else { return }
        let window = windowOwningPreviewFocus()
        let findResponder = window?.firstResponder.flatMap { cmuxFindTextFieldOwner(for: $0) }
        let shouldRestorePreviewFocus = findResponder?.window === window &&
            findResponder?.cmuxSelectionOwner === searchState
        if shouldRestorePreviewFocus {
            _ = window?.makeFirstResponder(nil)
        }
        self.searchState = nil
        if shouldRestorePreviewFocus {
            pendingPreviewFocus = false
            if displayMode == .preview,
               let webView = rendererSession.webView,
               webView.window === window {
                _ = window?.makeFirstResponder(webView)
            }
        }
    }

    /// Whether an async find-field focus request for `generation` may still
    /// be applied. Guards against focus theft after hide or a newer request.
    func canApplySearchFocusRequest(_ generation: UInt64) -> Bool {
        searchState != nil &&
            generation == searchFocusRequestGeneration &&
            activeSearchFocusRequestGeneration == generation
    }

    /// Invalidates deferred notifications that could otherwise reclaim focus.
    func invalidateSearchFocusRequests() {
        searchFocusRequestGeneration &+= 1
        activeSearchFocusRequestGeneration = nil
    }

    /// Posts a focus request only while its generation is still current.
    private func postSearchFocusNotification(generation: UInt64, selectAll: Bool) {
        guard canApplySearchFocusRequest(generation) else { return }
        NotificationCenter.default.post(
            name: .browserSearchFocus,
            object: id,
            userInfo: [FindFocusNotificationKey.selectAll: selectAll]
        )
    }

    /// Releases Markdown-owned AppKit responders when this pane is left.
    func unfocus() {
        pendingPreviewFocus = false
        invalidateSearchFocusRequests()

        guard let window = windowOwningPreviewFocus() else { return }
        _ = yieldFocusIntent(.panel, in: window)
    }

    /// Identifies a responder currently owned by this Markdown panel.
    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        ownsKeyboardResponder(responder, in: window) ? .panel : nil
    }

    @discardableResult
    /// Yields a previously identified Markdown responder to another panel.
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard intent == .panel,
              let firstResponder = window.firstResponder,
              ownsKeyboardResponder(firstResponder, in: window) else {
            return false
        }

        pendingPreviewFocus = false
        invalidateSearchFocusRequests()
        return window.makeFirstResponder(nil)
    }

    /// Finds the AppKit window containing the panel's current first responder.
    private func windowOwningPreviewFocus() -> NSWindow? {
        var candidates: [NSWindow] = []
        if let window = rendererSession.webView?.window {
            candidates.append(window)
        }
        if let keyWindow = NSApp.keyWindow {
            candidates.append(keyWindow)
        }
        if let mainWindow = NSApp.mainWindow {
            candidates.append(mainWindow)
        }
        candidates.append(contentsOf: NSApp.windows)

        var visited = Set<ObjectIdentifier>()
        for window in candidates {
            guard visited.insert(ObjectIdentifier(window)).inserted,
                  let firstResponder = window.firstResponder else {
                continue
            }
            if ownsKeyboardResponder(firstResponder, in: window) {
                return window
            }
        }

        return rendererSession.webView?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    /// Returns whether a responder belongs to this panel's input surfaces.
    private func ownsKeyboardResponder(_ responder: NSResponder, in window: NSWindow) -> Bool {
        if let searchState,
           let owner = cmuxFindTextFieldOwner(for: responder),
           owner.window === window,
           owner.cmuxSelectionOwner === searchState {
            return true
        }

        if let textView,
           textView.window === window,
           Self.responderChainContains(responder, target: textView) {
            return true
        }

        if let webView = rendererSession.webView,
           webView.window === window,
           Self.responderChainContains(responder, target: webView) {
            return true
        }

        return false
    }

    /// Checks a bounded AppKit responder chain for a target view.
    private static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var current = start
        var hops = 0
        while let responder = current, hops < 64 {
            if responder === target { return true }
            current = responder.nextResponder
            hops += 1
        }
        return false
    }
}
