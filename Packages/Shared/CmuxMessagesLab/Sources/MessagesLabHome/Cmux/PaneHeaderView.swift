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
/// titlebar: the header sits over the thread layer and takes the vendored
/// backdrop's blur and tint itself (`setThreadBlur`: a Gaussian filter and a
/// tint on its own pixels, the vendored animations' timing).
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

// MARK: The thread view's blur and tint on the header (round 10)

extension PaneHeaderView {
    static let blurName = "cmuxThreadBlur"
    static let tintName = "cmuxThreadTint"

    /// The header's own copy of ThreadBackdrop's effect while a thread or reply view is open: the same
    /// Gaussian blur (`ThreadBackdrop.radius`, the vendored CAFilter) as a filter on this header's layer,
    /// and the same tint (5.5 + 0.384 x in) composited onto the header's own pixels only ("sourceAtop":
    /// the band's transparent pixels stay clear, the band below takes the vendored tint once). `blur` and
    /// `tint`: the vendored backdrop's animations, whose begin time, duration and curve these take, so the
    /// header and the transcript change on the same frames. The filter is removed when the close ends
    /// (a filtered layer renders offscreen, where the pill's glass draws nothing; at rest it has none).
    func setThreadBlur(open: Bool, blur: CABasicAnimation?, tint: CABasicAnimation?) {
        guard let layer, open != threadBlurOpen else { return }
        threadBlurOpen = open
        threadBlurGeneration += 1
        let generation = threadBlurGeneration
        CATransaction.begin()
        if open {
            if layer.filters?.contains(where: { ($0 as? NSObject)?.value(forKey: "name") as? String == Self.blurName }) != true,
               let f = Self.makeBlurFilter() {
                CATransaction.setDisableActions(true)
                layer.filters = [f]
            }
            if threadTint.superlayer !== layer {
                threadTint.name = Self.tintName
                threadTint.backgroundColor = NSColor(white: ThreadBackdrop.base / 255 / (1 - ThreadBackdrop.gain), alpha: 1).cgColor
                threadTint.compositingFilter = "sourceAtop"
                threadTint.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
                threadTint.opacity = 0
                threadTint.zPosition = 1000
                layer.addSublayer(threadTint)
            }
            threadTint.frame = layer.bounds
        } else {
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.threadBlurGeneration == generation, !self.threadBlurOpen, let layer = self.layer else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.filters = nil
                self.threadTint.removeFromSuperlayer()
                CATransaction.commit()
            }
        }
        CATransaction.setDisableActions(true)
        let r0: CGFloat = open ? 0 : ThreadBackdrop.radius, r1: CGFloat = open ? ThreadBackdrop.radius : 0
        layer.setValue(r1, forKeyPath: "filters.\(Self.blurName).inputRadius")
        let b = CABasicAnimation(keyPath: "filters.\(Self.blurName).inputRadius")
        b.fromValue = r0; b.toValue = r1
        Self.time(b, like: blur, open: open)
        layer.add(b, forKey: "cmux.thread.blur")
        let t0: Float = open ? 0 : Float(1 - ThreadBackdrop.gain), t1: Float = open ? Float(1 - ThreadBackdrop.gain) : 0
        threadTint.opacity = t1
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = threadTint.presentation()?.opacity ?? t0; a.toValue = t1
        Self.time(a, like: tint ?? blur, open: open)
        threadTint.add(a, forKey: "cmux.thread.tint")
        CATransaction.commit()
    }

    /// `a` takes the vendored animation's begin time, duration and curve (ThreadBackdrop's constants when
    /// there is none).
    private static func time(_ a: CABasicAnimation, like vendored: CABasicAnimation?, open: Bool) {
        a.duration = vendored?.duration ?? (open ? ThreadBackdrop.openDuration : ThreadBackdrop.closeDuration)
        a.timingFunction = vendored?.timingFunction ?? CAMediaTimingFunction(name: .easeInEaseOut)
        if let begin = vendored?.beginTime, begin > 0 { a.beginTime = begin; a.fillMode = .backwards }
    }

    /// The vendored blur's filter (ThreadBackdrop.makeBlur's CAFilter), on a plain layer: no edge
    /// normalising, so the controls blur out into the clear band as Messages' do.
    private static func makeBlurFilter() -> NSObject? {
        guard let fc = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("filterWithType:")
        guard fc.responds(to: sel), let f = fc.perform(sel, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject else { return nil }
        f.setValue(blurName, forKey: "name")
        f.setValue(0, forKey: "inputRadius")
        return f
    }
}
