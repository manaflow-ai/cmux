import Foundation

/// Stop and Block for a Chromium tab's camera and microphone. Chromium has no API that ends a
/// page's capture, so Stop ends the tracks the page recorder kept (`BrowserPageBusy`, in every
/// frame it runs in); Block also stores Page Info's Block, which Chromium enforces from then on.
extension CEFTab: BrowserCaptureControlling {
    public func stopCapture() {
        Task { [weak self] in _ = try? await self?.evaluate(BrowserPageBusy.stopCaptureScript, world: .page, gesture: .cmux) }
    }

    public func blockCapture() { blockSiteCapture() }
}
