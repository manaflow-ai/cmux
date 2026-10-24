public import CoreGraphics

/// A woken Chromium tab's picture stays until its page paints (``CEFLayerHosting``):
/// only while the page is layer hosted, since a page window would draw over it.
extension CEFTab: BrowserWakeStandIn {
    public func showWakeStandIn(_ image: CGImage, cap: Duration) -> Bool {
        host.hostView.layerHosting.showStandIn(image, owner: ObjectIdentifier(self), cap: cap,
                                               hostingAvailable: runtime.forkAPIVersion >= CEFLayerHosting.forkAPI)
    }
}
