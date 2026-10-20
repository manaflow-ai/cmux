import CMUXMobileCore

/// Coalesces browser viewport layout changes into distinct display-link emissions.
struct BrowserStreamViewportEmissionPolicy: Equatable, Sendable {
    private var pending: MobileBrowserViewport?
    private var lastEmitted: MobileBrowserViewport?

    /// Records the newest valid viewport observed during layout.
    /// - Parameter viewport: Phone viewport measured by the content view.
    mutating func record(_ viewport: MobileBrowserViewport) {
        guard viewport.width > 0,
              viewport.height > 0,
              viewport.scale.isFinite,
              viewport.scale > 0 else {
            return
        }
        guard viewport != lastEmitted else {
            pending = nil
            return
        }
        pending = viewport
    }

    /// Returns the newest pending viewport once, suppressing unchanged values.
    mutating func takePending() -> MobileBrowserViewport? {
        guard let pending, pending != lastEmitted else {
            self.pending = nil
            return nil
        }
        self.pending = nil
        lastEmitted = pending
        return pending
    }
}
