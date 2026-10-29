import AppKit
import CmuxNextWakeups

/// A hosted page in an occluded window is told so: the fork's embedder visibility
/// `occluded`, as Chrome's `WebContentsViewCocoa` sets `Visibility::OCCLUDED` on its
/// tabs when its window is occluded (content/app_shim_remote_cocoa/web_contents_view_cocoa.mm,
/// `-updateWebContentsVisibility`). The renderer then draws no frames and reads as hidden, after
/// Chrome's one second of coalescing. Occluded means its window's ``WindowOcclusionFamily`` says so:
/// AppKit's state or an opaque cmux window covering it (crbug.com/883031).
extension CEFLayerHosting {
    /// What the fork should take for this page now: hidden while its view is hidden or out of a window,
    /// occluded while its window's family says so, else visible.
    var pageVisibility: PageVisibility {
        guard isViewShown else { return .hidden }
        let occluded = view?.window.flatMap(WindowOcclusionFamily.installed(on:))?.isOccluded ?? false
        return occluded ? .occluded : .visible
    }

    /// Follows the occlusion family of the view's window, a new one when the view changed windows: a
    /// flip reaches the fork after the commit like a show or hide (``visibilityMayHaveChanged()``).
    func followWindowOcclusion() {
        let window = view?.window
        guard window !== switchCommit.occlusionWindow else { return }
        switchCommit.occlusionWindow = window
        switchCommit.occlusionWatch = window.map { window in
            WindowOcclusionFamily.of(window).subscribe(.content, owner: "CEFLayerHosting") { [weak self] _ in
                self?.visibilityMayHaveChanged()
            }
        }
    }
}
