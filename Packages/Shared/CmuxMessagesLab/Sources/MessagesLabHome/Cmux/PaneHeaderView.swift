import AppKit

/// MessagesLab R76's header controls (HeaderBar.swift) inside the Home pane.
/// Blocker: HeaderBar installs an NSToolbar and a titlebar accessory on the
/// window, and a Home tab shares the cmux-next window. The same controls sit
/// in the pane over `HeaderBackdropView` (the blurred, darkened transcript),
/// at Messages' places: the 40 pt avatar 8 pt from the top, and the capsule
/// name pill (`HeaderBar.pillWidth`, bold 13 pt, the dim chevron) spanning
/// 44-72 pt (28 pt, centre 58), as Messages' (baseline
/// ref/real-bubble-stills-2x.png). cmux: the capsule is the system glass
/// material (`pillGlass`, LabGlass: NSGlassEffectView on macOS 26 and newer)
/// at exactly that frame, over the host's backing, under a borderless title
/// button (white on a dark theme): the glass button's bezel drew its capsule
/// 2-3 pt inside its frame, in light and dark differently (rounds 5-8), and a
/// self-drawn fill did not look like Messages' glass (round 9).
/// The disc overlaps the pill's top (disc 8-48 pt) and draws over it, whole,
/// as in Messages; the pill takes the clicks where they overlap. Under an open
/// thread or reply view the whole header, avatar and pill, blurs and dims as
/// Messages' (its tp0600 frame: the avatar a soft blob with no letter, the pill
/// a faint blur), and the thread's rows pass under it, as under Messages'
/// titlebar: the header sits over the thread layer, with its own blur over it
/// and a tint on its controls (`setThreadBlur`, the vendored animations' timing).
/// No band, no edge line, no video button (Home has no calls).
final class PaneHeaderView: NSView {
    let avatar = NSImageView()
    /// The pill's capsule: the system glass at the capsule's frame (its own fill, rim and highlight).
    let pillGlass = LabGlass.surface()
    let pill = NSButton()
    /// cmux: a small translucent capsule behind the pill, always shown, so
    /// its title reads over the rows when the header has no band
    /// (HeaderFade.swift). Clear until `setPillBacking(_:)`.
    let pillBacking = NSView()
    var title: String = "" { didSet { if title != oldValue { applyTitle() } } }
    /// The avatar's monogram (the conversation's other participant).
    var initials: String = "" { didSet { if initials != oldValue { applyAvatar() } } }
    /// A picture for the avatar (the Home Chief's), drawn in the disc over
    /// the monogram; nil shows the monogram.
    var picture: NSImage? { didSet { if picture !== oldValue { applyAvatar() } } }
    /// A light theme: the measured white disc would vanish on a light
    /// header, so the disc takes the theme's secondary text grey with a
    /// white monogram (Messages' light-mode avatar).
    var light = false { didSet { if light != oldValue { applyAvatar(); applyTitle() } } }
    var onContact: () -> Void = {}

    static let avatarSize: CGFloat = 40
    static let avatarTop: CGFloat = 8
    /// The thread view's effect on the header is on (`setThreadBlur`), its tint layer, and a counter that
    /// lets a close's completion that an open overtook do nothing.
    var threadBlurOpen = false
    let threadTint = CALayer()
    var threadBlurGeneration = 0
    /// The header's blur under an open thread view; the host adds it above this view.
    let threadBlurHost = HeaderThreadBlur()

    /// Messages' pill: 44-72 pt from the window top (centre 58, 28 pt), rim included.
    static let pillCenterY: CGFloat = 58
    static let pillHeight: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        avatar.imageScaling = .scaleProportionallyUpOrDown
        // Back to front: the host's backing, the pill's glass, the pill's title and chevron, the avatar:
        // the disc draws whole over the pill's top edge.
        pillBacking.wantsLayer = true
        addSubview(pillBacking)
        addSubview(pillGlass)
        // HeaderBar's pill, as configured there, its glass drawn by `pillGlass` (not the bezel).
        pill.isBordered = false
        pill.controlSize = .large
        pill.imagePosition = .imageTrailing
        pill.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 0.42, alpha: 1)])))
        pill.imageHugsTitle = true
        pill.font = .systemFont(ofSize: 13, weight: .bold)
        pill.target = self
        pill.action = #selector(contactClicked)
        addSubview(pill)
        addSubview(avatar)
        applyTitle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// The name pill takes its clicks; the rest of the header is the header
    /// itself: a click on the avatar opens the contact (as the pill does),
    /// and the empty space drags the window (cmux: Messages' header is its
    /// toolbar, so a drag there moves the window; the scroll view starts
    /// below the header).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        // The capsule takes its clicks, also where the avatar draws over its top edge (as Messages).
        if pill.frame.contains(p) && !pill.isHidden { return pill }
        return bounds.contains(p) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { true }

    /// The header acts on the first click, as the pill (an `NSButton`)
    /// and a native titlebar do: in a window that is not key (an inactive
    /// app, a background window) `NSWindow.sendEvent` passes a first click
    /// on only to a view that accepts it, so without this the avatar's
    /// click made the window key and never reached `mouseDown` (cx-3x9t).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The avatar opens the contact; elsewhere AppKit's window drag (with its
    /// snapping and Spaces behavior), not a move loop.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !avatar.isHidden, avatar.frame.contains(p) { onContact(); return }
        window?.performDrag(with: event)
    }

    override func layout() {
        super.layout()
        let s = PaneHeaderView.avatarSize
        avatar.frame = CGRect(x: (bounds.width - s) / 2, y: PaneHeaderView.avatarTop, width: s, height: s)
        let w = HeaderBar.pillWidth(title)
        let h = PaneHeaderView.pillHeight
        let capsule = CGRect(x: (bounds.width - w) / 2, y: PaneHeaderView.pillCenterY - h / 2, width: w, height: h)
        pill.frame = capsule
        pillBacking.frame = capsule
        pillBacking.layer?.cornerRadius = h / 2
        // On macOS 26 and newer the glass alone is the capsule, as Messages' (round 10: a backing under
        // it made the glass a flat fill); the backing stays for the stand-in material below 26.
        pillBacking.isHidden = pill.isHidden || PaneHeaderView.systemGlass
        pillGlass.frame = capsule
        pillGlass.cornerRadius = h / 2
        pillGlass.isHidden = pill.isHidden
        // The overlay matches this header's frame, so the avatar's frame reads the same in both.
    }

    private func applyTitle() {
        // Messages' title: white bold on the dark glass; the label colour on a light theme.
        pill.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: light ? NSColor.labelColor : NSColor.white,
        ])
        pill.isHidden = title.isEmpty
        avatar.isHidden = title.isEmpty
        pill.setAccessibilityLabel(String(format: NativeStrings.contactFormat, title))
        pill.toolTip = pill.accessibilityLabel()
        avatar.setAccessibilityLabel(title)
        needsLayout = true
    }

    @objc private func contactClicked() { onContact() }

    private func applyAvatar() {
        avatar.image = picture.map(PaneHeaderView.avatarImage(picture:)) ?? PaneHeaderView.avatarImage(initials, light: light)
    }

    /// The pill's capsule is the system glass (macOS 26 and newer).
    static var systemGlass: Bool { if #available(macOS 26, *) { return true } else { return false } }

    /// cmux: the pill's capsule color (translucent), under the glass below macOS 26; nil leaves it clear.
    func setPillBacking(_ color: NSColor?) {
        pillBacking.layer?.backgroundColor = color?.cgColor
    }

    /// A monogram on the header's avatar disc (white 253, as HeaderView
    /// draws it). HeaderBar draws the fixture contact's measured "I"; a Home
    /// conversation shows its participant's initials.
    static func avatarImage(_ initials: String, light: Bool = false) -> NSImage {
        let disc = light ? Fixture.secondaryText : NSColor(white: 253 / 255, alpha: 1)
        let ink: NSColor = light ? .white : .black
        return NSImage(size: NSSize(width: avatarSize, height: avatarSize), flipped: true) { r in
            disc.setFill()
            NSBezierPath(ovalIn: r).fill()
            let font = NSFont.systemFont(ofSize: initials.count > 1 ? 15 : 18, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let size = (initials as NSString).size(withAttributes: attrs)
            (initials as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
            return true
        }
    }

    /// A picture clipped to the avatar disc, filling it (its centered square).
    static func avatarImage(picture: NSImage) -> NSImage {
        NSImage(size: NSSize(width: avatarSize, height: avatarSize), flipped: false) { r in
            NSBezierPath(ovalIn: r).addClip()
            let size = picture.size, side = min(size.width, size.height)
            let square = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            picture.draw(in: r, from: square, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

// MARK: The thread view's blur and tint on the header (rounds 10-11)

extension PaneHeaderView {
    static let blurName = "gaussianBlur"

    /// Messages' header dims less than its transcript (round 11: header controls 164 -> 84, 0.51 of rest,
    /// where the vendored 5.5 + 0.384 x gives 0.42): the header's tint is fitted from those pixels,
    /// out = 5.5 + 0.479 x.
    static let headerGain: CGFloat = 0.479

    /// The thread view's effect on the header while a thread or reply view is open:
    /// - a tint on the controls' own shapes (the avatar's disc, the pill's capsule), out = 5.5 + 0.479 x,
    ///   under the blur;
    /// - over the header, `threadBlurHost` (the host adds it above this view): a CABackdropLayer with the
    ///   vendored Gaussian (radius `ThreadBackdrop.radius`) under a soft mask around the controls, so the
    ///   blur takes the controls as drawn, the pill's glass included (round 11: a filter on this layer
    ///   rendered it offscreen, where the glass draws nothing), and fades out into the band, which the
    ///   vendored backdrop under the header already blurs.
    /// Both take the vendored blur and tint animations' begin time, duration and curve. The backdrop leaves
    /// the tree when a close ends (no backdrop at rest or in a resize).
    func setThreadBlur(open: Bool, blur: CABasicAnimation?, tint: CABasicAnimation?) {
        guard let layer, open != threadBlurOpen else { return }
        threadBlurOpen = open
        threadBlurGeneration += 1
        let generation = threadBlurGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if open {
            if threadTint.superlayer !== layer {
                threadTint.backgroundColor = NSColor(white: ThreadBackdrop.base / 255 / (1 - Self.headerGain), alpha: 1).cgColor
                threadTint.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
                threadTint.opacity = 0
                threadTint.zPosition = 1000
                layer.addSublayer(threadTint)
            }
            threadTint.frame = layer.bounds
            let shapes = CAShapeLayer()
            let path = CGMutablePath()
            for r in controlShapes() { path.addRoundedRect(in: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2) }
            shapes.path = path
            shapes.frame = layer.bounds
            threadTint.mask = shapes
            threadBlurHost.install(over: frame, holes: controlShapes())
        } else {
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.threadBlurGeneration == generation, !self.threadBlurOpen else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.threadTint.removeFromSuperlayer()
                self.threadBlurHost.uninstall()
                CATransaction.commit()
            }
        }
        threadBlurHost.animate(open: open, like: blur)
        let t0: Float = open ? 0 : Float(1 - Self.headerGain), t1: Float = open ? Float(1 - Self.headerGain) : 0
        threadTint.opacity = t1
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = threadTint.presentation()?.opacity ?? t0; a.toValue = t1
        Self.time(a, like: tint ?? blur, open: open)
        threadTint.add(a, forKey: "cmux.thread.tint")
        CATransaction.commit()
    }

    /// The avatar's disc and the pill's capsule (this view's coordinates); none while they are hidden.
    func controlShapes() -> [CGRect] {
        var out: [CGRect] = []
        if !avatar.isHidden { out.append(avatar.frame) }
        if !pill.isHidden { out.append(pill.frame) }
        return out
    }

    /// `a` takes the vendored animation's begin time, duration and curve (ThreadBackdrop's constants when
    /// there is none).
    static func time(_ a: CABasicAnimation, like vendored: CABasicAnimation?, open: Bool) {
        a.duration = vendored?.duration ?? (open ? ThreadBackdrop.openDuration : ThreadBackdrop.closeDuration)
        a.timingFunction = vendored?.timingFunction ?? CAMediaTimingFunction(name: .easeInEaseOut)
        if let begin = vendored?.beginTime, begin > 0 { a.beginTime = begin; a.fillMode = .backwards }
    }
}

/// The header's blur under an open thread view (PaneHeaderView.setThreadBlur): a layer host over the
/// header holding a CABackdropLayer (the vendored Gaussian), under a soft mask around the controls. Never
/// hit. In the tree only while a thread view is open or closing.
final class HeaderThreadBlur: NSView {
    private var backdrop: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Over `header` (the superview's coordinates), masked softly around `holes` (the header's coordinates).
    func install(over header: CGRect, holes: [CGRect]) {
        if frame != header { frame = header }
        guard let layer else { return }
        let b = backdrop ?? ThreadBackdrop.makeBlur()
        guard let b else { return }
        b.actions = ["bounds": NSNull(), "position": NSNull()]
        b.frame = layer.bounds
        if b.superlayer !== layer { layer.addSublayer(b) }
        backdrop = b
        layer.mask = Self.softMask(size: layer.bounds.size, holes: holes)
        isHidden = false
    }

    func uninstall() {
        backdrop?.removeFromSuperlayer()
        backdrop = nil
        isHidden = true
    }

    func animate(open: Bool, like vendored: CABasicAnimation?) {
        guard let b = backdrop else { return }
        let key = "filters.gaussianBlur.inputRadius"
        let r0: CGFloat = open ? 0 : ThreadBackdrop.radius, r1: CGFloat = open ? ThreadBackdrop.radius : 0
        b.setValue(r1, forKeyPath: key)
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = r0; a.toValue = r1
        PaneHeaderView.time(a, like: vendored, open: open)
        b.add(a, forKey: "cmux.thread.blur")
    }

    /// Opaque around the controls (out to twice the blur radius), fading to clear over one more radius.
    static func softMask(size: CGSize, holes: [CGRect]) -> CALayer {
        let m = CALayer()
        m.frame = CGRect(origin: .zero, size: size)
        let w = max(1, Int(size.width.rounded(.up))), h = max(1, Int(size.height.rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return m }
        let r = ThreadBackdrop.radius
        // A shadow of shapes drawn far outside the bitmap: only the soft shadow lands inside.
        let away: CGFloat = 100_000
        ctx.setShadow(offset: CGSize(width: -away, height: 0), blur: r, color: CGColor(gray: 0, alpha: 1))
        ctx.setFillColor(gray: 0, alpha: 1)
        for hole in holes {
            let g = hole.insetBy(dx: -r * 2, dy: -r * 2)
            // CGContext is bottom-up; the header is flipped.
            let q = CGRect(x: g.minX + away, y: size.height - g.maxY, width: g.width, height: g.height)
            ctx.addPath(CGPath(roundedRect: q, cornerWidth: min(q.height, q.width) / 2, cornerHeight: min(q.height, q.width) / 2, transform: nil))
        }
        ctx.fillPath()
        m.contents = ctx.makeImage()
        return m
    }
}
