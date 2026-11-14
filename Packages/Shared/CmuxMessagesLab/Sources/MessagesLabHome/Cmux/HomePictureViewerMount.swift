import AppKit

/// Synchronous seam from the vendored, non-isolated ``ChatController`` click path into the main-actor
/// ``HomePictureViewer``: closes the open viewer over `host`, if any, and opens a new one there.
struct HomePictureViewerMount {
    /// The view the viewer covers (the chat pane's host).
    let host: NSView

    /// Opens `gallery` over ``host``, growing out of `thumbnail` (its frame in ``host`` and its picture) when given;
    /// false (nothing opened) off the main thread.
    func open(_ gallery: HomePictureGallery, from thumbnail: (rect: CGRect, image: CGImage)? = nil, load: @escaping HomePictureViewer.Load,
              onClose: @escaping () -> Void, onReply: @escaping (URL) -> Void) -> Bool {
        guard Thread.isMainThread else { return false }
        // main-proof: guarded by Thread.isMainThread above; clicks and the DEBUG socket drive arrive on main.
        return MainActor.assumeIsolated {
            for case let open as HomePictureViewer in host.subviews { open.close() }
            let viewer = HomePictureViewer(frame: host.bounds, gallery: gallery, load: load)
            viewer.onClose = onClose
            viewer.onReply = onReply
            host.addSubview(viewer, positioned: .above, relativeTo: nil)
            host.window?.makeFirstResponder(viewer)
            if let thumbnail { viewer.present(from: thumbnail.rect, thumbnail: thumbnail.image) }
            return true
        }
    }
}
