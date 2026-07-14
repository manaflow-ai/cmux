#if canImport(UIKit)
import CMUXMobileCore
import UIKit

extension GhosttySurfaceView {
    /// Atomically presents a complete Mac-authored terminal grid above the local renderer.
    ///
    /// The local Ghostty surface remains mounted for keyboard, accessory, viewport,
    /// and input plumbing. Its renderer is suppressed while the immutable grid view
    /// is visible, so VT replay cannot become user-visible output.
    /// - Parameter frame: A complete render-grid snapshot for this surface.
    /// - Returns: Whether the frame was presented, ignored as stale, or needs replay.
    public func presentAuthoritativeRenderGrid(
        _ frame: MobileTerminalRenderGridFrame
    ) -> AuthoritativeGridPresentationResult {
        let expectedSurfaceID = hostSurfaceID ?? frame.surfaceID
        let gridView = authoritativeGridView ?? makeAuthoritativeGridView(
            surfaceID: expectedSurfaceID
        )
        let result = gridView.present(frame)
        guard result == .presented else { return result }
        gridView.terminalFontSize = CGFloat(liveFontSize)
        gridView.isHidden = false
        isRenderDispatchSuppressed = true
        cursorOverlayLayer?.isHidden = true
        setGhosttyRendererLayersHidden(true)
        layoutAuthoritativeGridView()
        return result
    }

    /// Clears producer revision state for a replacement output-stream generation.
    /// - Parameter surfaceID: The surface identity the next full frame must carry.
    public func resetAuthoritativeRenderGrid(surfaceID: String) {
        authoritativeGridView?.reset(surfaceID: surfaceID)
    }

    /// Restores raw-byte Ghostty presentation for a host without render-grid support.
    public func useRawTerminalRenderer() {
        authoritativeGridView?.isHidden = true
        isRenderDispatchSuppressed = false
        setGhosttyRendererLayersHidden(false)
        needsDraw = true
        updateCursorOverlay()
    }

    var isAuthoritativeGridPresented: Bool {
        authoritativeGridView?.isHidden == false
    }

    func layoutAuthoritativeGridView() {
        guard let authoritativeGridView, !lastRenderRect.isEmpty else { return }
        authoritativeGridView.frame = lastRenderRect
    }

    private func makeAuthoritativeGridView(
        surfaceID: String
    ) -> AuthoritativeTerminalGridView {
        let gridView = AuthoritativeTerminalGridView(surfaceID: surfaceID)
        addSubview(gridView)
        authoritativeGridView = gridView
        return gridView
    }

    private func setGhosttyRendererLayersHidden(_ hidden: Bool) {
        for sublayer in layer.sublayers ?? [] where isGhosttyRendererLayer(sublayer) {
            sublayer.isHidden = hidden
        }
    }
}
#endif
