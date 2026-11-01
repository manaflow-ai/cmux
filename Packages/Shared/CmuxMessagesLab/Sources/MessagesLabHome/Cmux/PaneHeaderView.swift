import AppKit

/// MessagesLab R76's header controls (HeaderBar.swift) inside the Home pane.
/// Blocker: HeaderBar installs an NSToolbar and a titlebar accessory on the
/// window, and a Home tab shares the cmux-next window. The same controls sit
/// in the pane over `HeaderBackdropView` (the blurred, darkened transcript),
/// at HeaderBar's measured places: the 40 pt avatar centered 8 pt from the
/// top (the toolbar item), and the glass capsule name pill centered 58 pt
/// from the top (`HeaderBar.pillWidth`, bold 13 pt, the dim chevron). No
/// band, no edge line, no video button (Home has no calls).
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
    /// cmux: the pill's hover tooltip (the Chief's brain hint); nil shows its accessibility label.
    var pillToolTip: String? { didSet { if pillToolTip != oldValue { applyTitle() } } }
    /// cmux-classic: the conversation's status ("Waiting for you" while an approval waits): an
    /// attention dot on the avatar, the pill's accessibility value and tooltip. Nil: none.
    var status: String? { didSet { if status != oldValue { applyStatus() } } }
    private let statusDot = NSView()

    /// cmux-classic: 36 pt from 4 pt, so the pill (top at 44 pt) clears the avatar's chin by
    /// `avatarPillGap`; the 40 pt disc from 8 pt ran 4 pt under the pill (v3f a-first-run).
    static let avatarSize: CGFloat = 36
    static let avatarTop: CGFloat = 4
    /// The space between the avatar's bottom and the pill's top.
    static var avatarPillGap: CGFloat { (pillCenterY - pillHeight / 2) - (avatarTop + avatarSize) }
    /// HeaderBar: Messages' pill center, 58 pt from the window top.
    static let pillCenterY: CGFloat = 58
    static let pillHeight: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        addSubview(avatar)
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
        // cmux: a stable handle for UI tests and dogfood tours (the label is localized).
        pill.setAccessibilityIdentifier("HomeHeaderNamePill")
        addSubview(pill)
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusDot.layer?.borderWidth = 2
        statusDot.isHidden = true
        statusDot.setAccessibilityElement(false)
        addSubview(statusDot)
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
        pill.frame = CGRect(x: (bounds.width - w) / 2, y: PaneHeaderView.pillCenterY - h / 2, width: w, height: h)
        pillBacking.frame = pill.frame
        pillBacking.layer?.cornerRadius = h / 2
        pillBacking.isHidden = pill.isHidden
        // The attention dot sits on the avatar's lower right, ringed in the header's fill.
        let d: CGFloat = 12
        statusDot.frame = CGRect(x: avatar.frame.maxX - d + 1, y: avatar.frame.maxY - d + 1, width: d, height: d)
        statusDot.layer?.cornerRadius = d / 2
        statusDot.layer?.borderColor = Fixture.background.cgColor
    }

    private func applyStatus() {
        statusDot.isHidden = status == nil || avatar.isHidden
        pill.setAccessibilityValue(status)
        pill.toolTip = [pillToolTip ?? pill.accessibilityLabel(), status].compactMap { $0 }.joined(separator: " · ")
        needsLayout = true
    }

    private func applyTitle() {
        pill.title = title
        pill.isHidden = title.isEmpty
        avatar.isHidden = title.isEmpty
        pill.setAccessibilityLabel(String(format: NativeStrings.contactFormat, title))
        avatar.setAccessibilityLabel(title)
        applyStatus()
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
