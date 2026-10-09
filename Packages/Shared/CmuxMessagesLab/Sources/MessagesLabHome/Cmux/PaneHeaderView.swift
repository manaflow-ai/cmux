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
    var initials: String = "" { didSet { if initials != oldValue { avatar.image = PaneHeaderView.avatarImage(initials, light: light) } } }
    /// A light theme: the measured white disc would vanish on a light
    /// header, so the disc takes the theme's secondary text grey with a
    /// white monogram (Messages' light-mode avatar).
    var light = false { didSet { if light != oldValue { avatar.image = PaneHeaderView.avatarImage(initials, light: light) } } }
    var onContact: () -> Void = {}

    static let avatarSize: CGFloat = 40
    static let avatarTop: CGFloat = 8
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
        pill.bezelStyle = .glass
        pill.borderShape = .capsule
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
}
