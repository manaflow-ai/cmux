import Foundation
@testable import CmuxControlSocket

// Benign default implementations of the browser DOM-automation seam, so a
// test fake that conforms to the full `ControlCommandContext` umbrella only
// has to implement the domain it actually exercises (the per-domain companion
// to the shared `ControlCommandContextTestStubs.swift`).
//
// Note: the `controlBrowserAutomationState` default mints a fresh instance per
// access. A browser-domain test fake MUST override it with one stored
// instance so element refs/frame selectors persist across calls.
extension ControlBrowserAutomationContext {
    var controlBrowserAutomationState: ControlBrowserAutomationState { ControlBrowserAutomationState() }

    func controlBrowserResolvePanel(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlBrowserPanelResolution { .tabManagerUnavailable }

    func controlBrowserResolveWaitPanel(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlBrowserPanelResolution { .tabManagerUnavailable }

    func controlBrowserRunAutomationScript(
        surfaceID: UUID,
        script: String,
        timeout: TimeInterval,
        useEval: Bool
    ) -> ControlBrowserScriptOutcome { .failure("Browser operation failed") }

    func controlBrowserRunPageScript(
        surfaceID: UUID,
        script: String,
        timeout: TimeInterval
    ) -> ControlBrowserScriptOutcome { .failure("Browser operation failed") }

    func controlBrowserEnsureTelemetryHooks(surfaceID: UUID) {}

    func controlBrowserEnsureDialogHooks(surfaceID: UUID) {}

    func controlBrowserCaptureScreenshot(surfaceID: UUID) -> ControlBrowserScreenshotResult { .captureFailed }

    func controlBrowserAddPersistentUserScript(surfaceID: UUID, source: String) {}

    func controlBrowserResolvePendingDialog(dialogID: UUID, accept: Bool, text: String?) -> Bool { false }

    func controlBrowserPageTitle(surfaceID: UUID) -> String? { nil }
}
