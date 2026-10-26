import AppKit
import CmuxNextDesign
import QuartzCore

/// The row or group being dragged: a live row view on the one overlay glass
/// (`OverlaySurfaceView`: Liquid Glass on macOS 26+, the frosted material
/// before, opaque under Reduce Transparency) with a shadow. It keeps its
/// size and place: no lift scale (Lawrence 2026-10-20, u5506).
/// Multi-item drags show stacked cards behind it and a count badge.
final class DragLiftView: NSView {
    private let card = NSView()
    /// The card's background: the shared overlay material, never taking the pointer.
    let background: OverlaySurfaceView
    /// The card is glass (any overlay material but the opaque one).
    var isGlass: Bool { background.material != .opaque }
    private let content: NSView
    private var stack: [NSView] = []
    private let countBadge = ChromeLabel(labelWithString: "")
    let badgeBackground = NSView()
    private var lifted = false
    /// Landings started (`SidebarReorderLift.land`): only the last one's completion runs.
    var landings = 0
    /// A tall group's cut (`cap(to:fade:)`): the fading bottom edge over the content; nil shows it whole.
    private(set) var liftCap: SidebarLiftCap?

    /// `material` pins one overlay material (tests, galleries); nil follows this Mac.
    init(content: NSView, count: Int, material: OverlayMaterial? = nil) {
        self.content = content
        background = OverlaySurfaceView(material: material, interactive: false, cornerRadius: SidebarStyle.rowCornerRadius)
        super.init(frame: .zero)
        card.wantsLayer = true
        card.layer?.cornerRadius = SidebarStyle.rowCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        wantsLayer = true
        layer?.masksToBounds = false

        for depth in (1..<max(1, min(count, 3))).reversed() {
            let back = NSView()
            back.wantsLayer = true
            back.layer?.cornerRadius = SidebarStyle.rowCornerRadius
            back.layer?.cornerCurve = .continuous
            back.layer?.borderWidth = Metrics.lineWidth(0.5)
            back.identifier = NSUserInterfaceItemIdentifier("\(depth)")
            addSubview(back)
            stack.append(back)
        }
        addSubview(card)
        card.addSubview(background)
        background.contentView.addSubview(content)
        content.autoresizingMask = [.width, .height]

        if count > 1 {
            badgeBackground.wantsLayer = true
            badgeBackground.layer?.cornerCurve = .continuous
            countBadge.stringValue = "\(count)"
            countBadge.font = SidebarStyle.badgeFont
            countBadge.alignment = .center
            addSubview(badgeBackground)
            addSubview(countBadge)
        }
        layer?.shadowOpacity = 0
        layer?.shadowOffset = CGSize(width: 0, height: Metrics.space1)
        layer?.shadowRadius = Metrics.space2
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// A picture of the dragged rows: VoiceOver keeps the rows in the list, not a second selected copy.
    override func accessibilityChildren() -> [Any]? { [] }
    override func isAccessibilityElement() -> Bool { false }

    override func layout() {
        super.layout()
        card.frame = bounds
        background.frame = card.bounds
        content.frame = background.contentView.bounds
        if let liftCap { liftCap.place(height: bounds.height, width: bounds.width, animated: false) }
        for back in stack {
            let depth = CGFloat(Int(back.identifier?.rawValue ?? "1") ?? 1)
            back.frame = bounds.insetBy(dx: Metrics.space2 * depth, dy: 0).offsetBy(dx: 0, dy: Metrics.space2 * depth)
        }
        let size = countBadge.intrinsicContentSize
        let h = SidebarStyle.badgeHeight + Metrics.space1
        let w = max(h, size.width + Metrics.space4)
        badgeBackground.frame = NSRect(x: bounds.maxX - w + Metrics.space3, y: -h / 2, width: w, height: h)
        badgeBackground.layer?.cornerRadius = Metrics.chipCornerRadius(height: h)
        countBadge.frame = NSRect(x: badgeBackground.frame.minX, y: badgeBackground.frame.midY - size.height / 2, width: w, height: size.height)
        guard let layer else { return }
        // The shadow keeps the card's shape: `morph` springs it with the size.
        // The model always holds the current shape; a running spring (morph) keeps showing its own path until it ends there.
        Motion.sidebar.transaction(nil) { layer.shadowPath = shadowPath(bounds) }
    }

    private func shadowPath(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: SidebarStyle.rowCornerRadius, cornerHeight: SidebarStyle.rowCornerRadius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    private func updateColors() {
        performWithTheme {
            layer?.shadowColor = Palette.shadow.cgColor
            for back in stack {
                back.layer?.backgroundColor = Palette.elevatedBackground.withAlphaComponent(0.85).cgColor
                back.layer?.borderColor = Palette.separator.cgColor
            }
            badgeBackground.layer?.backgroundColor = Palette.textPrimary.cgColor
            countBadge.textColor = Palette.textOnPrimary
        }
    }

    /// Lifted: the one popover shadow (PopupStyle). Landing: it fades as the card settles.
    func setLifted(_ lifted: Bool, animated: Bool) {
        guard lifted != self.lifted, let layer else { return }
        self.lifted = lifted
        let elevation = PopupStyle.elevation2
        let opacity: Float = lifted ? Float(elevation.alpha) : 0
        let radius = elevation.layerRadius
        let offset = elevation.layerOffset(flipped: true)
        guard animated else {
            Motion.sidebar.transaction(nil) {
                layer.shadowOpacity = opacity
                layer.shadowRadius = radius
                layer.shadowOffset = offset
            }
            return
        }
        // Each property fades from what is on screen, so a quick drop during
        // the lift continues from the current shadow.
        // The card stays its size and in place: only the shadow lifts (u5506 dropped the 1.03 scale).
        Motion.sidebar.set(layer, "shadowOpacity", to: opacity, fade: .lift)
        Motion.sidebar.set(layer, "shadowRadius", to: radius, fade: .lift)
        Motion.sidebar.set(layer, "shadowOffset", to: NSValue(size: offset), fade: .lift)
    }

    /// Springs the card to `frame` (the shape the drop will take: a list row,
    /// a tile, a group member) with the one move spring (DESIGN "Drag feel" 2).
    /// The model frame changes at once and additive springs carry what is on
    /// screen from the old frame, so the pointer follow (model origin only)
    /// keeps composing with the morph and nothing jumps. Reduce Motion: a
    /// crossfade instead of the shape spring.
    func morph(to frame: NSRect) {
        guard frame != self.frame else { return }
        let layers = ([layer, card.layer, background.layer, content.layer]
            + background.subviews.map(\.layer)).compactMap { $0 }
        let before = layers.map { ($0, $0.position, $0.bounds.size) }
        let oldBounds = bounds
        let startPath = layer?.presentation()?.shadowPath ?? layer?.shadowPath
        let capStart = liftCap.map { $0.mask.position }
        Motion.withoutAnimation {
            self.frame = frame
            layoutSubtreeIfNeeded()
        }
        // The cut's fading edge rides on the card's bottom, on the same spring (it moves past the rows when the
        // card grows back to the whole group).
        if let cap = liftCap, let capStart {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cap.mask.position = capStart
            CATransaction.commit()
            cap.place(height: frame.height, width: frame.width, animated: Motion.sidebar.policy.animatesMovement)
        }
        guard Motion.sidebar.policy.animatesMovement else {
            if let layer { Motion.sidebar.set(layer, "opacity", to: Float(alphaValue), fade: .crossfade, from: Float(alphaValue) * 0.4) }
            return
        }
        morphs += 1
        // The shadow's shape springs with the card's size (one spring, from the shape on screen).
        if let layer, frame.size != oldBounds.size {
            Motion.sidebar.set(layer, "shadowPath", to: shadowPath(CGRect(origin: .zero, size: frame.size)), spring: .move,
                       from: startPath ?? shadowPath(oldBounds))
        }
        for (layer, position, size) in before {
            let dp = NSValue(point: NSPoint(x: position.x - layer.position.x, y: position.y - layer.position.y))
            let ds = NSValue(size: NSSize(width: size.width - layer.bounds.width, height: size.height - layer.bounds.height))
            for (path, delta, zero) in [("position", dp, NSValue(point: .zero)), ("bounds.size", ds, NSValue(size: .zero))] {
                let animation = Motion.sidebar.springAnimation(.move, path, from: delta, to: zero)
                animation.isAdditive = true
                layer.add(animation, forKey: "morph.\(path).\(morphs)")
            }
        }
    }

    private var morphs = 0

    /// Cuts the card to `height` (a tall group's header and first rows) on the move spring: the card's bottom
    /// moves up and the rows past the cut fade under a `fade` tall bottom edge (`SidebarLiftCap`). A later
    /// `morph` to the whole group's height (a landing) shows every row again. Does nothing for a card already
    /// that short.
    func cap(to height: CGFloat, fade: CGFloat) {
        guard height < bounds.height - 0.5, liftCap == nil else { return }
        let cap = SidebarLiftCap(full: bounds.height, fade: fade)
        content.wantsLayer = true
        cap.place(height: bounds.height, width: bounds.width, animated: false)
        content.layer?.mask = cap.mask
        liftCap = cap
        morph(to: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: height))
    }

    /// Dims the card when the current hover position cannot accept the drop.
    func setRefused(_ refused: Bool) {
        let target: CGFloat = refused ? 0.55 : 1
        guard alphaValue != target else { return }
        Motion.feedback.animate(.hover, in: self) { animator().alphaValue = target }
    }
}
