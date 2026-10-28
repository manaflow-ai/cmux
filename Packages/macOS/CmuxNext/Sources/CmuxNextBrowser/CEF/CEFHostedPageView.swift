import AppKit
import IOSurface
import QuartzCore

/// A hosted page's volatile snapshot on screen: the page's last frame, copied
/// before its renderer evicted it, over the page's surface in the stand-in slot, so a show presents it
/// in the switch's own commit with no decode and no copy. Chrome shows an evicted page's copied frame
/// the same way, in a layer over its surface layer until the first new frame arrives
/// (`DelegatedFrameHost::stale_content_layer_`, content/browser/renderer_host/delegated_frame_host.cc).
extension ChromiumHostPageView {
    /// Shows `snapshot` over the page's surface until ``removeSnapshotCover()``, in the stand-in slot
    /// (under the crash overlay), at the scale it was taken at: a pane resized meanwhile shows the page's
    /// background around it, never a stretched picture.
    func coverWithSnapshot(_ snapshot: IOSurface) {
        removeStandIn()
        let cover = SnapshotCover(frame: bounds, snapshot: snapshot)
        addSubview(cover, positioned: .above, relativeTo: surface)
        standIn = cover
    }

    /// The snapshot that covers the page now, if the stand-in is one.
    var snapshotCover: SnapshotCover? { standIn as? SnapshotCover }

    /// Takes the snapshot off the page; another stand-in stays.
    func removeSnapshotCover() {
        guard standIn is SnapshotCover else { return }
        removeStandIn()
    }

    /// The layer that shows a snapshot's IOSurface as its contents. It never takes the mouse: the page
    /// window above takes every event, as for the live page.
    final class SnapshotCover: NSView {
        /// The snapshot it shows.
        let snapshot: IOSurface

        init(frame: NSRect, snapshot: IOSurface) {
            self.snapshot = snapshot
            super.init(frame: frame)
            let layer = CALayer()
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer.contents = snapshot
            layer.contentsGravity = .topLeft
            // Pixels per point when it was taken: the view's size has not changed since the page hid.
            layer.contentsScale = frame.width >= 1 ? CGFloat(snapshot.width) / frame.width : 1
            self.layer = layer
            wantsLayer = true
            autoresizingMask = [.width, .height]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isFlipped: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}
