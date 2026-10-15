import AppKit

/// MessagesLab R76's header controls (HeaderBar.swift) inside the Home pane.
/// Blocker: HeaderBar installs an NSToolbar and a titlebar accessory on the
/// window, and a Home tab shares the cmux-next window. The same controls sit
/// in the pane over `HeaderBackdropView` (the blurred, darkened transcript),
/// at Messages' places: the 40 pt avatar 8 pt from the top, and the glass
/// capsule name pill (`HeaderBar.pillWidth`, bold 13 pt, the dim chevron)
/// whose drawn capsule spans 44-71 pt (baseline ref/real-bubble-stills-2x.png:
/// the pill's rim rows at 88 and 142 px). The disc overlaps the pill's top
/// (disc 8-48 pt) and draws over it, whole, as in Messages (the white disc
/// covers the pill's top edge); the pill takes the clicks where they overlap.
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
    var light = false { didSet { if light != oldValue { applyAvatar() } } }
    var onContact: () -> Void = {}

    static let avatarSize: CGFloat = 40
    static let avatarTop: CGFloat = 8
    /// HeaderBar: Messages' pill center, 58 pt from the window top.
    /// The drawn capsule's centre and height (Messages: 44-71 pt).
    static let pillCenterY: CGFloat = 57.5
    static let pillHeight: CGFloat = 27
    /// AppKit's glass button draws its capsule this far inside its frame, top and bottom
    /// (round 4 and 5 captures: a 28 pt frame at 44-72 pt drew its rim at 47-69 pt), so
    /// the frame is the drawn capsule outset by it.
    static let glassInset: CGFloat = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        // Back to front: the pill's backing, the pill (glass), the avatar: the disc draws whole
        // over the pill's top edge, as in Messages.
        pillBacking.wantsLayer = true
        addSubview(pillBacking)
        // HeaderBar's pill, as configured there.
        if #available(macOS 26, *) {
            pill.bezelStyle = .glass
            pill.borderShape = .capsule
        } else {
            pill.bezelStyle = .push
        }
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
        // The drawn capsule takes its clicks, also where the avatar draws over its top edge (as Messages).
        if pill.frame.insetBy(dx: 0, dy: PaneHeaderView.glassInset).contains(p) && !pill.isHidden { return pill }
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

    /// The avatar's disc and the pill's capsule in the superview's coordinates for a header of
    /// `width` (the thread rows' mask, PaneHost+ThreadLayer.swift); none while they are hidden.
    func controlRects(width: CGFloat) -> [CGRect] {
        guard !title.isEmpty else { return [] }
        let s = PaneHeaderView.avatarSize, w = HeaderBar.pillWidth(title), h = PaneHeaderView.pillHeight
        return [CGRect(x: (width - s) / 2, y: PaneHeaderView.avatarTop, width: s, height: s),
                CGRect(x: (width - w) / 2, y: PaneHeaderView.pillCenterY - h / 2, width: w, height: h)]
            .map { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
    }

    override func layout() {
        super.layout()
        let s = PaneHeaderView.avatarSize
        avatar.frame = CGRect(x: (bounds.width - s) / 2, y: PaneHeaderView.avatarTop, width: s, height: s)
        let w = HeaderBar.pillWidth(title)
        let h = PaneHeaderView.pillHeight
        let capsule = CGRect(x: (bounds.width - w) / 2, y: PaneHeaderView.pillCenterY - h / 2, width: w, height: h)
        pill.frame = capsule.insetBy(dx: 0, dy: -PaneHeaderView.glassInset)
        pillBacking.frame = capsule
        pillBacking.layer?.cornerRadius = h / 2
        pillBacking.isHidden = pill.isHidden
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

    /// cmux: the pill's capsule color (translucent); nil leaves it clear.
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
