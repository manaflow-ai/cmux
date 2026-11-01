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
    /// cmux: the capsule behind the pill. Clear: on macOS 26 the pill's own
    /// glass bezel is the capsule; before 26 it holds `pillGlass`
    /// (`useGlassPill()`). Never a dark fill (Lawrence 2026-10-20).
    let pillBacking = NSView()
    /// cmux: before macOS 26, the glass capsule under the borderless pill
    /// (`useGlassPill()`); nil on 26, where the pill is system glass.
    private(set) var pillGlass: (any LabGlassSurface)?
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
    /// cmux: the host's top-right controls (Home's panel toggles, like Claude desktop's), at the
    /// trailing edge on the avatar's line. They take their own clicks; nil shows none.
    var trailingAccessory: NSView? {
        didSet {
            guard trailingAccessory !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let trailingAccessory { addSubview(trailingAccessory) }
            needsLayout = true
        }
    }
    /// cmux: who else has the conversation open (chat multiplayer), beside the name pill; empty
    /// shows none. `facesLabel` is what VoiceOver reads for them (the host's localized words).
    let facesView = PaneHeaderFacesView()
    var faces: [PaneHeaderFace] {
        get { facesView.faces }
        set { facesView.faces = newValue; needsLayout = true }
    }
    var facesLabel: String = "" { didSet { facesView.setAccessibilityLabel(facesLabel) } }
    /// The gap between the name pill and the faces.
    static let facesGap: CGFloat = 8
    /// The accessory's distance from the header's trailing edge.
    static let trailingInset: CGFloat = 12
    /// cmux: Home's chat with no header (`HostView.useBareTop`): no avatar and no name pill; only
    /// the accessory shows, `bareAccessoryTop` under the pane's top.
    var bare = false { didSet { if bare != oldValue { applyTitle() } } }
    static let bareAccessoryTop: CGFloat = 8

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
        facesView.setAccessibilityElement(true)
        facesView.setAccessibilityRole(.group)
        addSubview(facesView)
        applyTitle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// The name pill takes its clicks, and so do the trailing accessory's
    /// controls; the rest of the header is the header itself: a click on the
    /// avatar opens the contact (as the pill does), and the empty space
    /// drags the window (cmux: Messages' header is its toolbar, so a drag
    /// there moves the window; the scroll view starts below the header). The
    /// accessory's own gaps drag too (its hit test finds no control there).
    /// Bare (Home with no header, `useBareTop`), only the accessory's controls take clicks: the rows
    /// under the rest of it keep theirs.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let p = convert(point, from: superview)
        if pill.frame.contains(p) && !pill.isHidden { return pill }
        if let accessory = trailingAccessory, !accessory.isHidden, accessory.frame.contains(p),
           let hit = accessory.hitTest(p), hit !== accessory { return hit }
        return bounds.contains(p) && !bare ? self : nil
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
        pillGlass?.frame = pillBacking.bounds
        pillGlass?.cornerRadius = h / 2
        layoutTrailingAccessory()
        layoutFaces()
    }

    /// The accessory at its intrinsic size (else its own frame size), centered on the avatar's line at the trailing edge;
    /// hidden in a pane so narrow it would reach the avatar.
    private func layoutTrailingAccessory() {
        guard let accessory = trailingAccessory else { return }
        let intrinsic = accessory.intrinsicContentSize
        let size = CGSize(width: intrinsic.width == NSView.noIntrinsicMetric ? accessory.frame.width : intrinsic.width,
                          height: intrinsic.height == NSView.noIntrinsicMetric ? accessory.frame.height : intrinsic.height)
        let centerY = PaneHeaderView.avatarTop + PaneHeaderView.avatarSize / 2
        let top = bare ? PaneHeaderView.bareAccessoryTop : centerY - size.height / 2
        let frame = CGRect(x: bounds.width - PaneHeaderView.trailingInset - size.width, y: top,
                           width: size.width, height: size.height)
        if accessory.frame != frame { accessory.frame = frame }
        let avatarFrame = CGRect(x: (bounds.width - PaneHeaderView.avatarSize) / 2, y: PaneHeaderView.avatarTop,
                                 width: PaneHeaderView.avatarSize, height: PaneHeaderView.avatarSize)
        accessory.isHidden = bare ? frame.minX < 0 : frame.minX < avatarFrame.maxX + 8
    }

    /// The faces after the name pill, centered on its line; hidden with the pill, with nobody else
    /// here, or in a pane too narrow to keep them clear of the trailing accessory.
    private func layoutFaces() {
        let size = facesView.intrinsicContentSize
        let frame = CGRect(x: pill.frame.maxX + PaneHeaderView.facesGap, y: PaneHeaderView.pillCenterY - size.height / 2,
                           width: size.width, height: size.height)
        if facesView.frame != frame { facesView.frame = frame }
        let limit = trailingAccessory.flatMap { $0.isHidden ? nil : $0.frame.minX - 8 } ?? bounds.width - PaneHeaderView.trailingInset
        facesView.isHidden = pill.isHidden || faces.isEmpty || frame.maxX > limit
    }

    private func applyTitle() {
        pill.title = title
        pill.isHidden = bare || title.isEmpty
        avatar.isHidden = pill.isHidden
        pill.setAccessibilityLabel(String(format: NativeStrings.contactFormat, title))
        pill.toolTip = pill.accessibilityLabel()
        avatar.setAccessibilityLabel(title)
        needsLayout = true
    }

    @objc private func contactClicked() { onContact() }

    private func applyAvatar() {
        avatar.image = picture.map(PaneHeaderView.avatarImage(picture:)) ?? PaneHeaderView.avatarImage(initials, light: light)
    }

    /// cmux: the name pill as glass. macOS 26 and newer: the pill's own
    /// glass bezel, nothing behind it. Before 26: a borderless pill on a
    /// glass capsule (`LabGlass`, a visual-effect view there). Once per header.
    func useGlassPill() {
        if #available(macOS 26, *) { return }
        guard pillGlass == nil else { return }
        let glass = LabGlass.surface()
        pillBacking.addSubview(glass)
        pillGlass = glass
        pill.isBordered = false
        needsLayout = true
    }

    /// The header's avatar for `initials`: letters and digits as Messages' grey
    /// gradient monogram (``MonogramAvatar``, like iMessage);
    /// anything else (an emoji) on the plain disc (white 253,
    /// as HeaderView draws it; the theme's secondary grey in a light theme).
    static func avatarImage(_ initials: String, light: Bool = false) -> NSImage {
        if MonogramAvatar.isMonogram(initials) {
            return MonogramAvatar(initials: initials).image(side: avatarSize, light: light)
        }
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
