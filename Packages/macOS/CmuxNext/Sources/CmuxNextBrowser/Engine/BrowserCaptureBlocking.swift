import Foundation

extension BrowserCaptureControlling where Self: BrowserTab & PageInfoProviding {
    /// Page Info's Block for camera and microphone on the page's site: the decision goes to
    /// the profile's shared store and the engine (one path with Page Info), then the capture
    /// in progress ends. Nothing when the page has no web origin.
    func blockSiteCapture() {
        guard let url = state.url, let origin = PageInfoSite.origin(of: url) else {
            stopCapture()
            return
        }
        let store = sitePermissions
        for kind in [SitePermissionKind.camera, .microphone] { store.set(.block, kind, for: origin) }
        stopCapture()
        Task { [weak self] in
            for kind in [SitePermissionKind.camera, .microphone] { await self?.pageInfoDidChange(kind, to: .block, origin: origin) }
        }
    }
}
