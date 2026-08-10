#if canImport(UIKit)
import CmuxMobileTerminal

extension GhosttySurfaceRepresentable.Coordinator {
    func setLocalPixelViewportActive(
        _ isActive: Bool,
        on surfaceView: GhosttySurfaceView
    ) {
        localPixelViewportActive = isActive
        refreshScrollPresentationAuthority(on: surfaceView)
    }

    func refreshScrollPresentationAuthority(on surfaceView: GhosttySurfaceView) {
        guard let store else { return }
        if localPixelViewportActive {
            surfaceView.scrollPresentationAuthority = .localPixelViewport
        } else if store.usesVerifiedTerminalReplay {
            surfaceView.scrollPresentationAuthority = .verifiedRenderGrid
        } else {
            surfaceView.scrollPresentationAuthority = .legacyMirror
        }
    }
}
#endif
