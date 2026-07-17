#if canImport(UIKit)
import CMUXMobileCore
import UIKit

extension GhosttySurfaceView {
    /// Classifies a complete frame before any viewport geometry is changed.
    public func classifyAuthoritativeRenderGrid(
        _ frame: MobileTerminalRenderGridFrame
    ) -> AuthoritativeGridPresentationResult {
        let expectedSurfaceID = hostSurfaceID ?? frame.surfaceID
        let gridView = authoritativeGridView ?? makeAuthoritativeGridView(
            surfaceID: expectedSurfaceID
        )
        return gridView.classify(frame)
    }

    /// Keeps Ghostty pixels hidden while an admitted frame changes geometry.
    public func prepareForAuthoritativeRenderGridPresentation() {
        setAuthoritativeGridAuthorityActive(true)
        suppressGhosttyPresentationForAuthoritativeGrid()
    }

    /// Atomically presents a complete Mac-authored terminal grid above the local renderer.
    ///
    /// The local Ghostty surface remains mounted for keyboard, accessory, viewport,
    /// and input plumbing. Its renderer is suppressed while the immutable grid view
    /// is visible. Ghostty's stale parser is not used in this mode.
    /// - Parameter frame: A complete render-grid snapshot for this surface.
    /// - Returns: Whether the frame was presented, ignored as stale, or needs replay.
    public func presentAuthoritativeRenderGrid(
        _ frame: MobileTerminalRenderGridFrame
    ) -> AuthoritativeGridPresentationResult {
        setAuthoritativeGridAuthorityActive(true)
        let expectedSurfaceID = hostSurfaceID ?? frame.surfaceID
        let gridView = authoritativeGridView ?? makeAuthoritativeGridView(
            surfaceID: expectedSurfaceID
        )
        let result = gridView.present(frame)
        guard result == .presented else { return result }
        gridView.terminalTheme = terminalTheme
        gridView.terminalFontSize = CGFloat(liveFontSize)
        gridView.isHidden = false
        isRenderDispatchSuppressed = true
        cursorOverlayLayer?.isHidden = true
        setGhosttyRendererLayersHidden(true)
        layoutAuthoritativeGridView()
        return result
    }

    /// Resets only producer ordering for a replacement output-stream generation.
    ///
    /// The last-good frame remains visible while resize/replay is awaited.
    /// - Parameter surfaceID: The surface identity the next full frame must carry.
    public func beginAuthoritativeRenderGridReplay(surfaceID: String) {
        setAuthoritativeGridAuthorityActive(true)
        authoritativeGridView?.beginReplay(surfaceID: surfaceID)
        suppressGhosttyPresentationForAuthoritativeGrid()
    }

    /// Clears direct pixels when the logical terminal is replaced or torn down.
    public func clearAuthoritativeRenderGrid(surfaceID: String) {
        authoritativeGridView?.clear(surfaceID: surfaceID)
        authoritativeGridView?.isHidden = true
        setAuthoritativeGridAuthorityActive(false)
    }

    /// Restores raw-byte Ghostty presentation for a host without render-grid support.
    public func useRawTerminalRenderer() {
        setAuthoritativeGridAuthorityActive(false)
        authoritativeGridView?.isHidden = true
        isRenderDispatchSuppressed = false
        setGhosttyRendererLayersHidden(false)
        needsDraw = true
        updateCursorOverlay()
    }

    var isAuthoritativeGridPresented: Bool {
        authoritativeGridView?.isHidden == false
    }

    var shouldHideGhosttyRenderer: Bool {
        Self.shouldHideRenderer(
            isRenderDispatchSuppressed: isRenderDispatchSuppressed,
            isAuthoritativeGridPresented: isAuthoritativeGridPresented
        )
    }

    func layoutAuthoritativeGridView() {
        guard let authoritativeGridView, !lastRenderRect.isEmpty else { return }
        authoritativeGridView.frame = lastRenderRect
    }

    private func makeAuthoritativeGridView(
        surfaceID: String
    ) -> AuthoritativeTerminalGridView {
        let gridView = AuthoritativeTerminalGridView(surfaceID: surfaceID)
        gridView.terminalTheme = terminalTheme
        gridView.isHidden = true
        addSubview(gridView)
        authoritativeGridView = gridView
        return gridView
    }

    private func setGhosttyRendererLayersHidden(_ hidden: Bool) {
        for sublayer in layer.sublayers ?? [] where isGhosttyRendererLayer(sublayer) {
            sublayer.isHidden = hidden
        }
    }

    private func suppressGhosttyPresentationForAuthoritativeGrid() {
        isRenderDispatchSuppressed = true
        cursorOverlayLayer?.isHidden = true
        setGhosttyRendererLayersHidden(true)
    }
}
#endif
