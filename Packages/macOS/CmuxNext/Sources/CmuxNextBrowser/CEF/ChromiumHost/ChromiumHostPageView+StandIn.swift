import AppKit

extension ChromiumHostPageView {
    /// Shows `picture` over the page's surface, under the crash overlay, until ``removeStandIn()``:
    /// the page's last picture while no host shows it (its host ended after its idle deadline),
    /// until the next host's first context shows. The page background fill stays under it.
    func showStandIn(_ picture: CGImage) {
        removeStandIn()
        let view = BrowserPictureView(picture: { picture })
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .above, relativeTo: surface)
        standIn = view
    }

    func removeStandIn() {
        standIn?.removeFromSuperview()
        standIn = nil
    }
}
