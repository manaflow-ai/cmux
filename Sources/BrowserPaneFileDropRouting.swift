import AppKit
import WebKit

/// How a file-URL drag over a browser pane should be handled.
enum BrowserPaneFileDropDisposition: Equatable {
    /// Forward the drag to the hosted WKWebView (HTML5 page upload).
    case forwardToPage
    /// Open the file in cmux (file-preview pane / split) via the workspace handlers.
    case previewInWorkspace
}

/// Routes browser-pane file drops by intent only: intent never depends on transient webview
/// availability; delivery failure refuses the drop instead of reinterpreting it.
enum BrowserPaneFileDropRouting {
    static func disposition(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        modifierFlags: NSEvent.ModifierFlags,
        isDockHosted: Bool,
        defaultBehavior: FileDropDefaultBehavior = FileDropBehaviorSettings.behavior()
    ) -> BrowserPaneFileDropDisposition? {
        guard DragOverlayRoutingPolicy.hasFileURL(pasteboardTypes) else { return nil }

        // A Dock-hosted browser pane has no workspace-tree file-preview destination, so a
        // file URL dropped over its page content always forwards to the hosted WKWebView
        // (normal page upload) regardless of the text/preview file-drop setting. This
        // preserves the pre-Dock-drop behavior, where the pane target did not claim the drop
        // and it fell through to the web view; without it, preview-mode (or Shift-inverted)
        // file drops on Dock browsers would be claimed by the pane target and rejected by the
        // Dock guard instead of reaching the page.
        if isDockHosted {
            return .forwardToPage
        }

        guard let behavior = DragOverlayRoutingPolicy.resolvedFileDropBehavior(
            pasteboardTypes: pasteboardTypes,
            modifierFlags: modifierFlags,
            canDropAsText: true,
            defaultBehavior: defaultBehavior
        ) else {
            return nil
        }

        switch behavior {
        case .text:
            return .forwardToPage
        case .preview:
            return .previewInWorkspace
        }
    }
}

@MainActor
extension BrowserPaneDropTargetView {
    var isDockHostedPane: Bool {
        dropContext.map { AppDelegate.shared?.dockForPane($0.paneId) != nil } ?? false
    }

    func fileDropDisposition(_ sender: any NSDraggingInfo) -> BrowserPaneFileDropDisposition? {
        BrowserPaneFileDropRouting.disposition(
            pasteboardTypes: sender.draggingPasteboard.types,
            modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
            isDockHosted: isDockHostedPane
        )
    }

    func webViewForFileDropDelivery(at location: NSPoint) -> WKWebView? {
        if let webView = slotView?.hostedWebViewForFileDrop(at: location) {
            return webView
        }

        guard let window,
              bounds.contains(location),
              let context = dropContext else {
            return nil
        }

        let windowPoint = convert(location, to: nil)
        guard let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(windowPoint, in: window),
              BrowserWindowPortalRegistry.paneDropContext(for: webView) == context else {
            return nil
        }

        // The registry lookup above hit-tests the whole slot container, not the
        // hosted web view's own frame. When the web view is live in this window it
        // may not fill the slot (a docked Web Inspector splits the slot with WebKit
        // companion views), so a primary-path miss means the drop point is over
        // non-page area: refuse instead of misrouting the drop into the page.
        // Only a detached web view (discarded / mid-reparent) skips the geometry
        // check; that transient gap is what this fallback exists for.
        if webView.window === window {
            let pointInWebView = webView.convert(windowPoint, from: nil)
            guard webView.bounds.contains(pointInWebView) else { return nil }
        }
        return webView
    }

    func updateHostedWebViewDragState(_ sender: any NSDraggingInfo, at location: NSPoint) -> NSDragOperation {
        guard let webView = webViewForFileDropDelivery(at: location) else {
            exitActiveFileDropWebView(sender)
            requestWebViewRestoreForFileDropIfNeeded()
            return []
        }
        if activeFileDropWebView !== webView {
            exitActiveFileDropWebView(sender)
            activeFileDropWebView = webView
            return webView.draggingEntered(sender)
        }
        return webView.draggingUpdated(sender)
    }

    func exitActiveFileDropWebView(_ sender: (any NSDraggingInfo)?) {
        if let webView = activeFileDropWebView {
            webView.draggingExited(sender)
            activeFileDropWebView = nil
        }
    }

    func requestWebViewRestoreForFileDropIfNeeded() {
        guard !didRequestWebViewRestoreForDrag,
              let context = dropContext else {
            return
        }
        didRequestWebViewRestoreForDrag = true
        guard let panel = AppDelegate.shared?
            .workspaceFor(tabId: context.workspaceId)?
            .panels[context.panelId] as? BrowserPanel else {
            return
        }
        panel.restoreDiscardedWebViewIfNeeded(reason: "browser_pane_file_drop")
    }
}
