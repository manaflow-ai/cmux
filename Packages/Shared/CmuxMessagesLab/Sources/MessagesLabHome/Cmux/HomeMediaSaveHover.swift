import AppKit

/// cmux: the save button of a picture or video in the transcript (user 2026-11-16, "image/video previews lowkey kinda
/// messy"). MessagesLab drew a round save glyph 14 pt beside every picture and video, always: it took no click, and it
/// sat at a different x for every picture width. Now it shows only while the pointer is over the picture, inside its
/// top trailing corner (the same place on every picture), and a click on it opens Save As… (the menu's row).
///
/// The button is a layer in the row's cell (it scrolls with the picture); it hides when the pointer leaves the picture,
/// the transcript scrolls, or the row is drawn for another message.
final class HomeMediaSaveHover {
    /// The button's side, its inset from the picture's top trailing corner, and its corner radius: the picture's
    /// corner radius (`Fixture.bubbleRadius`, 15 pt) less the inset, so the two corners are concentric.
    static let side: CGFloat = 28
    static let inset: CGFloat = 6
    static let radius: CGFloat = Fixture.bubbleRadius - inset

    /// What the button is over: the message, the attachment, and the button's frame in the transcript's coordinates.
    struct Target: Equatable, Sendable {
        var message: ID
        var attachment: ID
        var name: String
        var frame: CGRect
    }

    private(set) var target: Target?
    private let layer = CALayer()
    private let glyph = CALayer()
    private weak var parent: CALayer?

    init() {
        layer.cornerRadius = Self.radius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 0.5
        layer.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        layer.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        layer.opacity = 0
        layer.zPosition = 10
        glyph.contentsGravity = .resizeAspect
        layer.addSublayer(glyph)
    }

    /// The button's frame in a picture's frame `body`: its top trailing corner, inset.
    static func frame(in body: CGRect) -> CGRect {
        CGRect(x: body.maxX - inset - side, y: body.minY + inset, width: side, height: side)
    }

    /// Whether a picture of this size shows the button (a picture smaller than two buttons keeps only the menu).
    static func fits(_ body: CGRect) -> Bool { body.width >= 2 * side + 2 * inset && body.height >= side + 2 * inset }

    /// Shows the button on the picture under `p` (transcript coordinates), or hides it.
    func update(_ hit: (target: Target, parent: CALayer, frameInParent: CGRect)?, pressed: Bool = false) {
        guard let hit else { hide(); return }
        let moved = hit.target != target || hit.parent !== parent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if moved {
            layer.removeFromSuperlayer()
            hit.parent.addSublayer(layer)
            parent = hit.parent
            layer.frame = hit.frameInParent
            let scale = hit.parent.contentsScale > 0 ? hit.parent.contentsScale : 2
            layer.contentsScale = scale
            glyph.contentsScale = scale
            glyph.contents = glyphImage(scale: scale)
            let g: CGFloat = 13
            glyph.frame = CGRect(x: (Self.side - g) / 2, y: (Self.side - g) / 2 - 0.5, width: g, height: g)
        }
        layer.backgroundColor = NSColor(white: 0, alpha: pressed ? 0.68 : 0.5).cgColor
        CATransaction.commit()
        if moved || target == nil {
            fade(to: 1, duration: 0.12)
        }
        target = hit.target
    }

    func hide(animated: Bool = true) {
        guard target != nil else { return }
        target = nil
        if animated { fade(to: 0, duration: 0.1) } else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.opacity = 0
            CATransaction.commit()
        }
    }

    /// Opacity only (no size or position change), ease-out, none with Reduce Motion.
    private func fade(to value: Float, duration: CFTimeInterval) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = value
        CATransaction.commit()
        guard !MessagesLabHomeView.reducesMotion, from != value else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = value
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        layer.add(a, forKey: "fade")
    }

    /// The white download glyph at the last scale it was drawn for.
    private var glyphCache: (scale: CGFloat, image: CGImage?)?
    private func glyphImage(scale: CGFloat) -> CGImage? {
        if let cached = glyphCache, cached.scale == scale { return cached.image }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = NSSize(width: 13, height: 13)
        let pixels = CrashGuard.int((13 * scale).rounded(.up), in: 13...64) // no trap on a NaN scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = symbol.size
        let k = min(size.width / s.width, size.height / s.height)
        let drawn = NSRect(x: (size.width - s.width * k) / 2, y: (size.height - s.height * k) / 2, width: s.width * k, height: s.height * k)
        symbol.draw(in: drawn)
        NSColor.white.set()
        drawn.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        let image = rep.cgImage
        glyphCache = (scale, image)
        return image
    }
}

extension MessagesWindowView {
    /// The picture or video under `p` whose save button shows: its button's frame in the transcript's coordinates and
    /// in the layer it goes in (the row's cell, or the open thread's row view). Nil over anything else, over a picture
    /// still uploading or not delivered, and over one too small for the button.
    func mediaSaveTarget(_ p: CGPoint) -> (target: HomeMediaSaveHover.Target, parent: CALayer, frameInParent: CGRect)? {
        func check(_ spec: RowSpec, view: UIView) -> (target: HomeMediaSaveHover.Target, parent: CALayer, frameInParent: CGRect)? {
            guard case let .part(row) = spec.kind, case let .attachment(a) = row.part, a.kind == "image" || a.kind == "video",
                  !row.failed, !StreamBubble.isStream(row.ref.messageId) else { return nil }
            if case .uploading = a.transfer { return nil }
            let local = RowDraw.bodyRect(spec)
            guard HomeMediaSaveHover.fits(local) else { return nil }
            let body = view.convert(local, to: self)
            guard body.contains(p) else { return nil }
            let target = HomeMediaSaveHover.Target(message: row.ref.messageId, attachment: a.id, name: a.fileName,
                                                   frame: HomeMediaSaveHover.frame(in: body))
            return (target, view.layer, HomeMediaSaveHover.frame(in: local))
        }
        if threadOpen {
            for (v, spec) in zip(threadViews, threadSpecs).reversed() { if let found = check(spec, view: v) { return found } }
            return nil
        }
        for case let cell as RowCell in collection.visibleCells {
            guard let spec = cell.spec else { continue }
            if let found = check(spec, view: cell) { return found }
        }
        return nil
    }
}

private let saveHoverKey = AssociationKey()

extension ChatController {
    /// This pane's picture save button (made on first hover).
    var mediaSaveHover: HomeMediaSaveHover {
        if let hover = objc_getAssociatedObject(self, saveHoverKey.pointer) as? HomeMediaSaveHover { return hover }
        let hover = HomeMediaSaveHover()
        objc_setAssociatedObject(self, saveHoverKey.pointer, hover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return hover
    }

    /// The pointer moved to `p` (host coordinates) over the transcript, or left it (nil).
    func pointerMovedForSaveHover(_ p: CGPoint?) {
        guard let p, picker == nil, let demo else { mediaSaveHoverIfMade?.hide(); return }
        let found = demo.mediaSaveTarget(p)
        if found == nil, mediaSaveHoverIfMade == nil { return }
        mediaSaveHover.update(found, pressed: found.map { $0.target.frame.contains(p) } ?? false)
    }

    /// A press on the save button at `p`: Save As… for its picture. True when the press was the button's.
    func pressSaveHover(at p: CGPoint) -> Bool {
        guard let hover = mediaSaveHoverIfMade, let target = hover.target, target.frame.contains(p) else { return false }
        let window = host.window
        // task-owner: one fetch (the original may download); ends when the save panel opens
        Task { @MainActor [weak self] in
            guard let resolve = self?.attachmentResolver(target.message, target.attachment), let file = await resolve() else { return }
            HomeAttachmentSave().ask(file, name: target.name, window: window)
        }
        return true
    }

    private var mediaSaveHoverIfMade: HomeMediaSaveHover? {
        objc_getAssociatedObject(self, saveHoverKey.pointer) as? HomeMediaSaveHover
    }

    /// Scrolling hides the button (the row under the pointer changes without a pointer move): the transcript's
    /// scroll position callback calls this.
    func scrolledForSaveHover() { mediaSaveHoverIfMade?.hide(animated: false) }
}
