public import Foundation

/// The browser DOM-automation slice of the control-command seam (a
/// constituent of the ``ControlCommandContext`` umbrella): element actions,
/// JS eval plumbing, frames, and dialogs.
///
/// The conformer (`TerminalController`) keeps everything that is irreducibly
/// app-coupled — the WKWebView JS execution/run-loop pump
/// (`v2RunBrowserJavaScript` / `v2RunJavaScript`, shared with the still-app-side
/// nav/tab/network browser bodies), the viewport snapshot capture, WKUserScript
/// injection, and the dialog completion handlers — while every script string,
/// retry loop, payload shape, and piece of selection state lives in the
/// coordinator. Every method is `@MainActor`: the coordinator runs there, so
/// these are plain in-isolation calls (the legacy per-command `v2MainSync`
/// hops disappear).
@MainActor
public protocol ControlBrowserAutomationContext: AnyObject {
    /// The single browser DOM-automation state instance (element refs, frame
    /// selectors, init scripts/styles, pending dialogs). Owned by the
    /// conformer so the app-side browser bodies that still read it
    /// (snapshot ref minting, `state.save`/`state.load`, surface cleanup)
    /// share it with the coordinator.
    var controlBrowserAutomationState: ControlBrowserAutomationState { get }

    /// Resolves the browser panel a DOM-automation command targets, mirroring
    /// the legacy `v2BrowserWithPanel` + `v2ResolveBrowserSurfaceId`
    /// precedence: explicit surface (`surface_id` ?? `tab_id`), else the
    /// selected surface of an explicit `pane_id`, else the workspace's
    /// focused surface.
    ///
    /// - Parameters:
    ///   - routing: The shared routing selectors (TabManager + workspace).
    ///   - surfaceID: The explicit browser surface param, if present.
    /// - Returns: The resolution outcome.
    func controlBrowserResolvePanel(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlBrowserPanelResolution

    /// Resolves the browser panel for `browser.wait`, whose legacy resolution
    /// differs: explicit `surface_id` only (no `tab_id`/`pane_id`), else the
    /// workspace's focused surface.
    ///
    /// - Parameters:
    ///   - routing: The shared routing selectors.
    ///   - surfaceID: The explicit `surface_id` param, if present.
    /// - Returns: The resolution outcome (the pane cases are never produced).
    func controlBrowserResolveWaitPanel(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlBrowserPanelResolution

    /// Runs a frame-scoped automation script on a surface's web view: the
    /// legacy `v2RunBrowserJavaScript` (frame prelude from the current frame
    /// selector, async envelope, page-world with isolated-world retry), with
    /// the result bridged through the legacy `v2NormalizeJSValue` rules.
    ///
    /// - Parameters:
    ///   - surfaceID: The browser surface.
    ///   - script: The script source.
    ///   - timeout: The evaluation timeout in seconds.
    ///   - useEval: Whether the script runs through `eval(...)` (legacy
    ///     `useEval: true`) or is inlined as an expression.
    /// - Returns: The bridged outcome.
    func controlBrowserRunAutomationScript(
        surfaceID: UUID,
        script: String,
        timeout: TimeInterval,
        useEval: Bool
    ) -> ControlBrowserScriptOutcome

    /// Runs a raw page-world script on a surface's web view (the legacy bare
    /// `v2RunJavaScript(..., contentWorld: .page)` used by
    /// `browser.dialog.accept`/`dismiss`): no frame prelude, no eval envelope.
    ///
    /// - Parameters:
    ///   - surfaceID: The browser surface.
    ///   - script: The script source.
    ///   - timeout: The evaluation timeout in seconds.
    /// - Returns: The bridged outcome.
    func controlBrowserRunPageScript(
        surfaceID: UUID,
        script: String,
        timeout: TimeInterval
    ) -> ControlBrowserScriptOutcome

    /// Installs the page-telemetry bootstrap hooks on a surface (the legacy
    /// `v2BrowserEnsureTelemetryHooks`, best-effort).
    ///
    /// - Parameter surfaceID: The browser surface.
    func controlBrowserEnsureTelemetryHooks(surfaceID: UUID)

    /// Installs the dialog-telemetry bootstrap hooks on a surface (the legacy
    /// `v2BrowserEnsureDialogHooks`, best-effort).
    ///
    /// - Parameter surfaceID: The browser surface.
    func controlBrowserEnsureDialogHooks(surfaceID: UUID)

    /// Captures the surface's visible viewport as PNG data for
    /// `browser.screenshot` (the legacy 15s `v2AwaitCallback` around
    /// `captureAutomationVisibleViewportSnapshot` + PNG encode).
    ///
    /// - Parameter surfaceID: The browser surface.
    /// - Returns: The capture outcome.
    func controlBrowserCaptureScreenshot(surfaceID: UUID) -> ControlBrowserScreenshotResult

    /// Adds a persistent `WKUserScript` (document-start, all frames) to the
    /// surface's web view, as `browser.addinitscript`/`browser.addstyle` did.
    ///
    /// - Parameters:
    ///   - surfaceID: The browser surface.
    ///   - source: The script source.
    func controlBrowserAddPersistentUserScript(surfaceID: UUID, source: String)

    /// Runs the stored WKWebView completion handler for a pending native
    /// dialog popped from ``ControlBrowserAutomationState``, keyed by
    /// ``ControlBrowserPendingDialog/dialogID`` (the redesigned transport for
    /// the closure the legacy `V2BrowserPendingDialog` carried).
    ///
    /// - Parameters:
    ///   - dialogID: The dialog's completion-handler key.
    ///   - accept: Whether the dialog was accepted.
    ///   - text: The prompt text, if any.
    /// - Returns: Whether a stored completion handler was found and run.
    func controlBrowserResolvePendingDialog(dialogID: UUID, accept: Bool, text: String?) -> Bool

    /// The surface's current page title for `browser.get.title` (the legacy
    /// `browserPanel.pageTitle` read).
    ///
    /// - Parameter surfaceID: The browser surface.
    /// - Returns: The page title, or `nil` when the surface is no longer a
    ///   browser.
    func controlBrowserPageTitle(surfaceID: UUID) -> String?
}
