import AppKit
import CmuxControlSocket
import Foundation
import WebKit

/// The browser DOM-automation witnesses: the irreducibly app-coupled slices
/// of the former `v2Browser*` bodies (panel resolution, the WKWebView JS
/// pump, viewport snapshot capture, WKUserScript injection, dialog completion
/// handlers). Everything else — script strings, retry loops, payload shapes,
/// element-ref/frame/dialog state — moved into `ControlCommandCoordinator`.
///
/// The JS pump (`v2RunBrowserJavaScript` / `v2RunJavaScript` /
/// `v2NormalizeJSValue` / `v2AwaitCallback`) stays on the controller because
/// the still-app-side nav/tab/network browser bodies share it; these
/// witnesses forward to it and bridge results to `Sendable` values.
extension TerminalController: ControlBrowserAutomationContext {
    // MARK: - Panel location

    /// The workspace-resolution twin of the legacy
    /// `v2ResolveWorkspace(params:tabManager:)`, reading the selectors the
    /// coordinator already resolved.
    private func browserAutomationResolveWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let wsId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = routing.paneID, let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    /// Locates the browser panel for a previously-resolved surface (the
    /// resolved ids cross the seam; the panel is re-looked-up per reach).
    private func browserAutomationPanel(surfaceID: UUID) -> BrowserPanel? {
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
            return nil
        }
        return workspace.browserPanel(for: surfaceID)
    }

    func controlBrowserResolvePanel(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlBrowserPanelResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = browserAutomationResolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }

        // The browser-surface precedence of the legacy v2ResolveBrowserSurfaceId:
        // explicit surface, else the selected surface of an explicit pane, else
        // the workspace's focused surface.
        let resolvedSurfaceID: UUID?
        if let surfaceID {
            resolvedSurfaceID = surfaceID
        } else if let paneID = routing.paneID {
            guard let pane = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneID }) else {
                return .paneNotFound(paneID)
            }
            guard let selectedTab = ws.bonsplitController.selectedTab(inPane: pane),
                  let selectedSurface = ws.panelIdFromSurfaceId(selectedTab.id) else {
                return .paneHasNoSelectedSurface(paneID)
            }
            resolvedSurfaceID = selectedSurface
        } else {
            resolvedSurfaceID = ws.focusedPanelId
        }

        guard let resolvedSurfaceID else {
            return .noFocusedBrowserSurface
        }
        guard ws.browserPanel(for: resolvedSurfaceID) != nil else {
            return .surfaceNotBrowser(resolvedSurfaceID)
        }
        return .resolved(workspaceID: ws.id, surfaceID: resolvedSurfaceID)
    }

    func controlBrowserResolveWaitPanel(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlBrowserPanelResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = browserAutomationResolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard let resolvedSurfaceID = surfaceID ?? ws.focusedPanelId else {
            return .noFocusedBrowserSurface
        }
        guard ws.browserPanel(for: resolvedSurfaceID) != nil else {
            return .surfaceNotBrowser(resolvedSurfaceID)
        }
        return .resolved(workspaceID: ws.id, surfaceID: resolvedSurfaceID)
    }

    // MARK: - JS execution bridges

    /// Bridges a raw JS evaluation value to the `Sendable` script value:
    /// top-level `undefined` sentinel first, then the legacy
    /// `v2NormalizeJSValue` rules (which also rewrite nested sentinels into
    /// the eval envelope), then the lossless `JSONValue` bridge.
    private func browserAutomationBridge(_ value: Any?) -> ControlBrowserScriptValue {
        if value is V2BrowserUndefinedSentinel {
            return .undefined
        }
        let normalized = v2NormalizeJSValue(value)
        return .value(JSONValue(foundationObject: normalized) ?? .null)
    }

    func controlBrowserRunAutomationScript(
        surfaceID: UUID,
        script: String,
        timeout: TimeInterval,
        useEval: Bool
    ) -> ControlBrowserScriptOutcome {
        guard let panel = browserAutomationPanel(surfaceID: surfaceID) else {
            return .failure("Browser operation failed")
        }
        switch v2RunBrowserJavaScript(
            panel.webView,
            surfaceId: surfaceID,
            script: script,
            timeout: timeout,
            useEval: useEval
        ) {
        case .failure(let message):
            return .failure(message)
        case .success(let value):
            return .success(browserAutomationBridge(value))
        }
    }

    func controlBrowserRunPageScript(
        surfaceID: UUID,
        script: String,
        timeout: TimeInterval
    ) -> ControlBrowserScriptOutcome {
        guard let panel = browserAutomationPanel(surfaceID: surfaceID) else {
            return .failure("Browser operation failed")
        }
        switch v2RunJavaScript(panel.webView, script: script, timeout: timeout, contentWorld: .page) {
        case .failure(let message):
            return .failure(message)
        case .success(let value):
            return .success(browserAutomationBridge(value))
        }
    }

    func controlBrowserEnsureTelemetryHooks(surfaceID: UUID) {
        guard let panel = browserAutomationPanel(surfaceID: surfaceID) else { return }
        _ = v2RunJavaScript(
            panel.webView,
            script: BrowserPanel.telemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    func controlBrowserEnsureDialogHooks(surfaceID: UUID) {
        guard let panel = browserAutomationPanel(surfaceID: surfaceID) else { return }
        _ = v2RunJavaScript(
            panel.webView,
            script: BrowserPanel.dialogTelemetryHookBootstrapScriptSource,
            timeout: 5.0,
            contentWorld: .page
        )
    }

    // MARK: - Screenshot capture

    /// PNG-encodes a captured snapshot image (was `v2PNGData`, whose only
    /// caller was the screenshot body).
    private func browserAutomationPNGData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func controlBrowserCaptureScreenshot(surfaceID: UUID) -> ControlBrowserScreenshotResult {
        guard let panel = browserAutomationPanel(surfaceID: surfaceID) else {
            return .captureFailed
        }
        let snapshotResult: Data?? = v2AwaitCallback(timeout: 15.0) { finish in
            panel.captureAutomationVisibleViewportSnapshot { result in
                switch result {
                case .success(let image):
                    finish(self.browserAutomationPNGData(from: image))
                case .failure:
                    finish(nil)
                }
            }
        }

        guard let snapshotResult else {
            return .timedOut
        }
        guard let imageData = snapshotResult else {
            return .captureFailed
        }
        return .png(imageData)
    }

    // MARK: - User scripts

    func controlBrowserAddPersistentUserScript(surfaceID: UUID, source: String) {
        guard let panel = browserAutomationPanel(surfaceID: surfaceID) else { return }
        let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        panel.webView.configuration.userContentController.addUserScript(userScript)
    }

    // MARK: - Dialog completion handlers

    /// Queues a native WKWebView dialog for socket-driven resolution (the
    /// redesigned twin of the legacy `enqueueBrowserDialog` on the
    /// controller). The Sendable ``ControlBrowserPendingDialog`` value goes
    /// into the shared automation state; the WKWebView completion handler
    /// stays app-side, keyed by the dialog's `dialogID`. Entries dropped by
    /// the legacy 16-entry bound release their handlers unrun, exactly as the
    /// legacy queue dropped its responder closures unrun.
    func enqueueBrowserDialog(
        surfaceId: UUID,
        type: String,
        message: String,
        defaultText: String?,
        responder: @escaping (_ accept: Bool, _ text: String?) -> Void
    ) {
        let dialog = ControlBrowserPendingDialog(
            dialogID: UUID(),
            surfaceID: surfaceId,
            kind: type,
            message: message,
            defaultText: defaultText
        )
        browserDialogRespondersByDialogID[dialog.dialogID] = responder
        for droppedDialogID in controlBrowserAutomationState.enqueueDialog(dialog) {
            browserDialogRespondersByDialogID.removeValue(forKey: droppedDialogID)
        }
    }

    func controlBrowserResolvePendingDialog(dialogID: UUID, accept: Bool, text: String?) -> Bool {
        guard let responder = browserDialogRespondersByDialogID.removeValue(forKey: dialogID) else {
            return false
        }
        responder(accept, text)
        return true
    }

    // MARK: - Reads

    func controlBrowserPageTitle(surfaceID: UUID) -> String? {
        browserAutomationPanel(surfaceID: surfaceID)?.pageTitle
    }
}
