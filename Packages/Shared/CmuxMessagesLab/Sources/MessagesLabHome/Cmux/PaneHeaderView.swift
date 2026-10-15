import AppKit
import CoreImage

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
    /// Messages' bright lower rim, over the glass.
    let pillRim = NSView()
    let pillRimLine = CAShapeLayer()
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
    var threadBlurGeneration = 0
    /// The header's blur under an open thread view; the host adds it above this view.
    let threadBlurHost = HeaderThreadBlur()

    /// Messages' pill: 44-72 pt from the window top (centre 58, 28 pt), rim included.
    static let pillCenterY: CGFloat = 58
    static let pillHeight: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Own layers for the controls: an open thread view fades them (setThreadBlur), also before the
        // header is in a window, when AppKit has made no layer for a subview yet.
        for v in [avatar, pill] as [NSView] { v.wantsLayer = true }
        avatar.imageScaling = .scaleProportionallyUpOrDown
        // Back to front: the host's backing, the pill's glass, the pill's title and chevron, the avatar:
        // the disc draws whole over the pill's top edge.
        pillBacking.wantsLayer = true
        addSubview(pillBacking)
        addSubview(pillGlass)
        // Messages' pill (round 12 A/B: the closest system variant is clear glass with a 15 % white tint;
        // Messages' bright lower rim, 157 on its tp0000 crop, is drawn over it).
        if #available(macOS 26, *), let glass = pillGlass as? NSGlassEffectView {
            glass.style = .clear
            glass.tintColor = NSColor(white: 1, alpha: 0.15)
        }
        pillRim.wantsLayer = true
        pillRim.layer?.addSublayer(pillRimLine)
        addSubview(pillRim)
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
        pillRim.frame = capsule
        pillRim.isHidden = pill.isHidden
        placeRim(in: CGRect(origin: .zero, size: capsule.size))
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

    /// Messages' bright lower rim: a 1 pt line along the capsule's lower edge, white, strongest at the
    /// bottom and fading out by mid-height.
    private func placeRim(in r: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        pillRimLine.frame = r
        let line = r.insetBy(dx: 0.5, dy: 0.5)
        pillRimLine.path = CGPath(roundedRect: line, cornerWidth: line.height / 2, cornerHeight: line.height / 2, transform: nil)
        pillRimLine.fillColor = nil
        pillRimLine.strokeColor = NSColor(white: 1, alpha: light ? 0.6 : 0.55).cgColor
        pillRimLine.lineWidth = 1
        let fade = (pillRimLine.mask as? CAGradientLayer) ?? CAGradientLayer()
        fade.frame = r
        // pillRim is not flipped: (0.5, 0) is the capsule's bottom.
        fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.clear.cgColor]
        pillRimLine.mask = fade
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

// MARK: The thread view's blur and tint on the header (rounds 10-12)

extension PaneHeaderView {
    /// Messages' header dims less than its transcript. Round 12 measured our header controls at 0.437 of
    /// rest with 0.479 where Messages' are 0.51 (tp0000 -> tp0600 over the avatar and pill boxes, its blur
    /// included); the box mean scales with the gain, so 0.479 x 0.51 / 0.437.
    static let headerGain: CGFloat = 0.559
    /// The blurred pill's body (Messages' glass, its tp0000 mean over the body: rgb 78, 94, 117), the
    /// shape the blur spreads into Messages' tp0600 plateau. A light theme takes a light grey.
    static func blurredPillFill(light: Bool) -> NSColor {
        light ? NSColor(white: 0.93, alpha: 1) : NSColor(srgbRed: 78 / 255, green: 94 / 255, blue: 117 / 255, alpha: 1)
    }

    /// The thread view's effect on the header while a thread or reply view is open. No backdrop samples
    /// the window (round 12: a soft-masked CABackdropLayer cut a lighter rectangle at the band's bottom,
    /// blurred rows passing under it, and could not sample the pill's glass): the controls are drawn into
    /// an image (the avatar, the pill as a capsule of the glass's measured colour, its title), blurred
    /// with the vendored radius (CoreImage Gaussian) and tinted out = 5.5 + 0.559 x, and `threadBlurHost`
    /// (over the header) shows that image while the live controls fade out, on the vendored tint
    /// animation's begin time, duration and curve. The blurred image fades to transparent by itself: no
    /// mask, no edge, nothing sampled from the rows below. Out of the tree at rest.
    func setThreadBlur(open: Bool, blur: CABasicAnimation?, tint: CABasicAnimation?) {
        guard open != threadBlurOpen else { return }
        threadBlurOpen = open
        threadBlurGeneration += 1
        let generation = threadBlurGeneration
        let timing = tint ?? blur
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if open {
            let scale = window?.backingScaleFactor ?? 2
            threadBlurHost.show(Self.blurredControls(self, scale: scale), over: frame, scale: scale)
        } else {
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.threadBlurGeneration == generation, !self.threadBlurOpen else { return }
                self.threadBlurHost.hide()
            }
        }
        // Cross-fade: the blurred, tinted image in, the live controls out (and back on close).
        threadBlurHost.fade(to: open ? 1 : 0, like: timing, open: open)
        for v in [avatar, pill, pillGlass] as [NSView] {
            guard let l = v.layer else { continue }
            let to: Float = open ? 0 : 1
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = l.presentation()?.opacity ?? l.opacity; a.toValue = to
            Self.time(a, like: timing, open: open)
            l.opacity = to
            l.add(a, forKey: "cmux.thread.fade")
        }
        CATransaction.commit()
    }

    /// The controls as Messages' blurred titlebar shows them: drawn sharp into a bitmap of the header's
    /// size with room for the blur, blurred with ThreadBackdrop's radius and tinted 5.5 + 0.559 x.
    static func blurredControls(_ header: PaneHeaderView, scale: CGFloat) -> CGImage? {
        let size = header.bounds.size
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)  // the header is flipped
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        if !header.pill.isHidden {
            let r = header.pill.frame
            blurredPillFill(light: header.light).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            let title = header.pill.attributedTitle
            let t = title.size()
            title.draw(at: CGPoint(x: r.midX - t.width / 2, y: r.midY - t.height / 2))
        }
        if !header.avatar.isHidden, let img = header.avatar.image { img.draw(in: header.avatar.frame) }
        NSGraphicsContext.restoreGraphicsState()
        guard let sharp = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: sharp)
        let gain = headerGain, base = ThreadBackdrop.base / 255
        // Not clamped to the extent before the blur: the controls fade to transparent at their edges.
        let soft = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: ThreadBackdrop.radius * scale])
            .cropped(to: input.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: base, y: base, z: base, w: 0),
            ])
        return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any]).createCGImage(soft, from: input.extent)
    }

    /// `a` takes the vendored animation's begin time, duration and curve (ThreadBackdrop's constants when
    /// there is none).
    static func time(_ a: CABasicAnimation, like vendored: CABasicAnimation?, open: Bool) {
        a.duration = vendored?.duration ?? (open ? ThreadBackdrop.openDuration : ThreadBackdrop.closeDuration)
        a.timingFunction = vendored?.timingFunction ?? CAMediaTimingFunction(name: .easeInEaseOut)
        if let begin = vendored?.beginTime, begin > 0 { a.beginTime = begin; a.fillMode = .backwards }
    }
}

/// The header's blurred controls under an open thread view (PaneHeaderView.setThreadBlur): a layer host
/// over the header showing one image. Never hit; hidden at rest.
final class HeaderThreadBlur: NSView {
    let image = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        image.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        image.opacity = 0
        layer?.addSublayer(image)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ picture: CGImage?, over header: CGRect, scale: CGFloat) {
        if frame != header { frame = header }
        image.frame = bounds
        image.contents = picture
        image.contentsScale = scale
        image.contentsGravity = .resize
        isHidden = false
    }

    func hide() {
        image.contents = nil
        isHidden = true
    }

    func fade(to v: Float, like vendored: CABasicAnimation?, open: Bool) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = image.presentation()?.opacity ?? image.opacity; a.toValue = v
        PaneHeaderView.time(a, like: vendored, open: open)
        image.opacity = v
        image.add(a, forKey: "cmux.thread.fade")
    }
}
