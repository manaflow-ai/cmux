import AppKit

/// MessagesLab R76's header controls (HeaderBar.swift) inside the Home pane.
/// Blocker: HeaderBar installs an NSToolbar and a titlebar accessory on the
/// window, and a Home tab shares the cmux-next window. The same controls sit
/// in the pane over `HeaderBackdropView` (the blurred, darkened transcript),
/// at Messages' places: the 40 pt avatar 8 pt from the top, and the capsule
/// name pill (`HeaderBar.pillWidth`, bold 13 pt, the dim chevron) spanning
/// 44-72 pt (28 pt, centre 58), as Messages' (baseline
/// ref/real-bubble-stills-2x.png). cmux: the capsule is drawn here (a fill and
/// a 0.5 pt rim, `pillBacking`) under a borderless title button, not AppKit's
/// glass bezel, whose rim landed 1-2 pt off in light and dark (rounds 5-8).
/// The disc overlaps the pill's top (disc 8-48 pt) and draws over it, whole,
/// as in Messages; the pill takes the clicks where they overlap. The avatar
/// draws in `avatarOverlay`, which the host places over the thread view's blur:
/// under an open thread Messages only dims the avatar (its edges stay sharp),
/// while the pill blurs with the transcript (round 8 capture).
/// No band, no edge line, no video button (Home has no calls).
final class PaneHeaderView: NSView {
    let avatar = NSImageView()
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
    var light = false { didSet { if light != oldValue { applyAvatar(); applyRim() } } }
    var onContact: () -> Void = {}

    static let avatarSize: CGFloat = 40
    static let avatarTop: CGFloat = 8
    /// Messages' pill: 44-72 pt from the window top (centre 58, 28 pt), rim included.
    static let pillCenterY: CGFloat = 58
    static let pillHeight: CGFloat = 28
    /// The capsule's rim (Messages' glass edge, a light hairline).
    static let pillRim: CGFloat = 0.5

    /// The avatar's own layer host (the host adds it over the thread view's blur): the disc and its
    /// dimming tint (ThreadBackdrop's), never hit (clicks reach this header's `mouseDown`).
    let avatarOverlay = AvatarOverlay()

    override init(frame: NSRect) {
        super.init(frame: frame)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        // Back to front: the pill's capsule (drawn here), the pill's title and chevron; the avatar
        // draws in `avatarOverlay`, over them: the disc draws whole over the pill's top edge.
        pillBacking.wantsLayer = true
        pillBacking.layer?.borderWidth = PaneHeaderView.pillRim
        addSubview(pillBacking)
        // HeaderBar's pill, as configured there, without its glass bezel (the capsule is drawn).
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
        avatarOverlay.addSubview(avatar)
        applyTitle()
        applyRim()
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
        pillBacking.isHidden = pill.isHidden
        // The overlay matches this header's frame, so the avatar's frame reads the same in both.
        if avatarOverlay.frame != frame { avatarOverlay.frame = frame }
        avatarOverlay.place(avatar.frame)
    }

    private func applyTitle() {
        pill.title = title
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

    /// cmux: the pill's capsule color (translucent); nil keeps the default fill.
    func setPillBacking(_ color: NSColor?) {
        pillBacking.layer?.backgroundColor = (color ?? PaneHeaderView.defaultPillFill(light: light)).cgColor
        pillFillSet = color != nil
    }
    private var pillFillSet = false

    /// Messages' glass capsule as drawn: a fill and a light hairline rim (dark: white 18 %; light:
    /// black 12 %), the fill until the host sets its own (`setPillBacking`).
    private func applyRim() {
        pillBacking.layer?.borderColor = (light ? NSColor(white: 0, alpha: 0.12) : NSColor(white: 1, alpha: 0.18)).cgColor
        if !pillFillSet { pillBacking.layer?.backgroundColor = PaneHeaderView.defaultPillFill(light: light).cgColor }
    }

    static func defaultPillFill(light: Bool) -> NSColor {
        light ? NSColor(white: 0.97, alpha: 0.85) : NSColor(white: 0.27, alpha: 0.85)
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

/// The header avatar's own layer host (PaneHeaderView.avatarOverlay): the disc, and over it
/// ThreadBackdrop's tint (its colour and opacity, out = 5.5 + 0.384 x in), clipped to the disc, faded
/// with the window view's thread backdrop (`setDimmed`). The host places it over the thread view's
/// blur, so under an open thread the avatar dims without blurring, as Messages' does. Never hit.
final class AvatarOverlay: NSView {
    let tint = CALayer()
    private(set) var dimmed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        tint.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "cornerRadius": NSNull()]
        tint.backgroundColor = NSColor(white: ThreadBackdrop.base / 255 / (1 - ThreadBackdrop.gain), alpha: 1).cgColor
        tint.opacity = 0
        tint.masksToBounds = true
        tint.zPosition = 1
        layer?.addSublayer(tint)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The tint over the disc at `disc` (this view's coordinates).
    func place(_ disc: CGRect) {
        guard tint.frame != disc else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.frame = disc
        tint.cornerRadius = disc.width / 2
        CATransaction.commit()
    }

    /// ThreadBackdrop.animate's tint: the same opacity, duration and curve, begun at this commit (the
    /// window view's backdrop starts at the same one).
    func setDimmed(_ on: Bool) {
        guard on != dimmed else { return }
        dimmed = on
        let to: Float = on ? Float(1 - ThreadBackdrop.gain) : 0
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = tint.presentation()?.opacity ?? tint.opacity
        a.toValue = to
        a.duration = on ? ThreadBackdrop.openDuration : ThreadBackdrop.closeDuration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        tint.opacity = to
        tint.add(a, forKey: "thread")
    }
}
