import AppKit

/// cmux: real Messages blurs and darkens the header's avatar and name pill with the transcript
/// under an open thread or reply view (thread-open-esc reference: the avatar 237 -> 103). The
/// vendored ThreadBackdrop (WindowView's thread layer, a live blur and tint) only reaches what is
/// under it in the window view's layer tree, and Home's header (`PaneHeaderView`) is AppKit views
/// above that tree, so it stayed sharp (the pill lost 7 % of its light). While a view is open, a
/// picture of the header sits in the window view's tree just above the rows (`clip`), under the
/// thread layer, and the live header is hidden: the backdrop blurs and darkens the picture on its
/// own curve, open and close. The live header comes back when the close animation has ended.
final class ThreadHeaderCover {
    private weak var controller: ChatController?
    private var picture: CALayer?
    /// The picture of a view that is closing, until its close animation ends.
    private var closing: CALayer?
    /// Bumped by every open and close: a close's completion that an open overtook does nothing.
    private var generation = 0

    init(controller: ChatController) { self.controller = controller }

    /// After every engine change (ChatController.afterEngine): the cover follows `openThread`.
    func follow(open: Bool) {
        if open { show() } else { hide() }
    }

    private func show() {
        guard picture == nil else { return }
        // Opened again during a close: the closing picture stays (the live header is still hidden).
        if let l = closing {
            generation += 1
            closing = nil
            picture = l
            l.removeAnimation(forKey: "cmux.threadHeader")
            return
        }
        guard let controller, let demo = controller.demo, controller.window != nil else { return }
        let header = controller.host.paneHeader
        guard !header.isHidden, header.bounds.width > 0, header.bounds.height > 0,
              demo.clip.layer.superlayer === demo.layer,
              let rep = header.bitmapImageRepForCachingDisplay(in: header.bounds) else { return }
        header.cacheDisplay(in: header.bounds, to: rep)
        guard let image = rep.cgImage else { return }
        generation += 1
        let l = CALayer()
        l.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        l.contents = image
        l.contentsScale = CGFloat(rep.pixelsWide) / header.bounds.width
        l.frame = controller.host.convert(header.frame, from: header.superview)
        // Drawn the same way up as the rows' bitmaps: a layer under an odd number of flipped
        // ancestors draws its contents the other way up than one under an even number.
        if let cell = demo.collection.visibleCells.compactMap({ $0 as? RowCell }).first,
           l.contentsAreFlipped() != cell.bitmap.contentsAreFlipped() {
            l.isGeometryFlipped.toggle()
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        demo.layer.insertSublayer(l, above: demo.clip.layer)
        CATransaction.commit()
        header.isHidden = true
        picture = l
    }

    private func hide() {
        guard let l = picture else { return }
        picture = nil
        closing = l
        generation += 1
        let token = generation
        // The picture stays under the backdrop for the close (ThreadBackdrop.closeDuration); a
        // no-op animation on it times the swap back to the live header.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == token, self.closing === l else { return }
            self.closing = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            l.removeFromSuperlayer()
            CATransaction.commit()
            self.controller?.host.paneHeader.isHidden = false
        }
        let hold = CABasicAnimation(keyPath: "opacity")
        hold.fromValue = 1
        hold.toValue = 1
        hold.duration = ThreadBackdrop.closeDuration
        l.add(hold, forKey: "cmux.threadHeader")
        CATransaction.commit()
    }
}
