import AppKit
import CmuxNextDesign

/// The notices over the Chief pet, as the references stack them (chief-chat-source-captures
/// d154d558 and ea6f2499): glass capsules with a bold title and one muted line. Folded, the newest
/// is in front and up to two more peek out below it as a deck; the rail's chevron unfolds them
/// into a column. A child window of the pet, so it moves with every drag; never key.
final class ChiefPetBubblePanel: NSPanel {
    static let accessibilityID = "cmux.chiefPet.bubble"
    /// The references' capsule is about 330 x 56 pt (d154d558, a @2x capture).
    static let width: CGFloat = 330
    static let pillHeight: CGFloat = 56
    /// How far each folded notice behind the front one peeks out below it, and how much narrower it is per side.
    static let deckStep: CGFloat = 8
    static let deckInset: CGFloat = 16
    /// Between unfolded capsules.
    static let spacing: CGFloat = 8
    /// Between the notices and the pet: the references float them well clear of it.
    static let gap: CGFloat = 48

    /// A click on the notice at this index of the feed.
    var onOpen: ((Int) -> Void)?
    let bubble = ChiefPetBubbleView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.pillHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        // Agent output and replies stay out of screen shares and recordings.
        sharingType = .none
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setAccessibilityIdentifier(Self.accessibilityID)
        bubble.frame = contentLayoutRect
        bubble.autoresizingMask = [.width, .height]
        bubble.onOpen = { [weak self] in self?.onOpen?($0) }
        contentView = bubble
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The height for `count` notices, folded into a deck or unfolded into a column (three at most).
    static func height(count: Int, expanded: Bool) -> CGFloat {
        let shown = CGFloat(max(1, min(count, ChiefPetFeed.limit)))
        return expanded ? shown * pillHeight + (shown - 1) * spacing : pillHeight + (shown - 1) * deckStep
    }

    /// Centered over `pet`, `gap` above it; below it when the screen's top is too close.
    static func frame(height: CGFloat, over pet: CGRect, in visible: CGRect, width: CGFloat = ChiefPetBubblePanel.width,
                      gap: CGFloat = ChiefPetBubblePanel.gap) -> CGRect {
        var frame = CGRect(x: pet.midX - width / 2, y: pet.maxY + gap, width: width, height: height)
        if frame.maxY > visible.maxY { frame.origin.y = pet.minY - gap - height }
        frame.origin = ChiefPetPlacement.clamped(frame.origin, size: frame.size, in: visible)
        return frame
    }
}

/// The capsules. `show` redraws only when what it shows changed.
final class ChiefPetBubbleView: NSView {
    var onOpen: ((Int) -> Void)?
    private let capsules = (0..<ChiefPetFeed.limit).map { _ in ChiefPetCapsule() }
    /// What it draws now: identical content is never drawn (or animated) again.
    private(set) var shown: (content: [[String]], expanded: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The front capsule is drawn last, over the ones behind it.
        for capsule in capsules.reversed() { addSubview(capsule) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Draws `notices` (newest first), folded or unfolded; false when it already shows exactly that.
    @discardableResult
    func show(_ notices: [ChiefPetNotice], expanded: Bool) -> Bool {
        let notices = Array(notices.prefix(ChiefPetFeed.limit))
        let content = notices.map(\.content)
        if let shown, shown.content == content, shown.expanded == expanded { return false }
        shown = (content, expanded)
        for (index, capsule) in capsules.enumerated() {
            capsule.isHidden = index >= notices.count
            guard index < notices.count else { continue }
            // Folded, only the front capsule shows its text; the deck behind it is bare.
            capsule.show(notices[index], text: expanded || index == 0)
        }
        needsLayout = true
        return true
    }

    override func layout() {
        super.layout()
        let pill = ChiefPetBubblePanel.pillHeight
        let expanded = shown?.expanded ?? false
        for (index, capsule) in capsules.enumerated() {
            let i = CGFloat(index)
            if expanded {
                capsule.frame = CGRect(x: 0, y: bounds.height - pill - i * (pill + ChiefPetBubblePanel.spacing), width: bounds.width, height: pill)
            } else {
                let inset = i * ChiefPetBubblePanel.deckInset
                capsule.frame = CGRect(x: inset, y: bounds.height - pill - i * ChiefPetBubblePanel.deckStep, width: bounds.width - inset * 2, height: pill)
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The capsule under `point` (in this view), front first; folded, only the front one is a target.
    func capsuleIndex(at point: CGPoint) -> Int? {
        let targets = (shown?.expanded ?? false) ? capsules.indices.filter { !capsules[$0].isHidden } : [0]
        return targets.first { capsules[$0].frame.contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        capsuleIndex(at: convert(point, from: superview)) == nil ? nil : self
    }

    /// Taken here, so the release comes back to this view (AppKit sends mouseUp to the view that took the press).
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let index = capsuleIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(index)
    }
}

/// One notice: a glass capsule (the solid overlay surface under Reduce Transparency) with the
/// title in bold and one muted line under it, no status glyph, as the references draw it.
final class ChiefPetCapsule: NSView {
    private let surface: NSView
    private let title = ChromeLabel(labelWithString: "")
    private let detail = ChromeLabel(labelWithString: "")

    override init(frame: NSRect) {
        let radius = ChiefPetBubblePanel.pillHeight / 2
        surface = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? Glass.makeOverlayPanel(cornerRadius: radius) as NSView
            : Glass.makePanel(style: .regular, cornerRadius: radius, interactive: true)
        super.init(frame: frame)
        surface.translatesAutoresizingMaskIntoConstraints = true
        addSubview(surface)
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ notice: ChiefPetNotice, text: Bool) {
        title.stringValue = notice.title
        detail.stringValue = notice.detail
        title.isHidden = !text
        detail.isHidden = !text || notice.detail.isEmpty
        setAccessibilityLabel([notice.title, notice.detail].filter { !$0.isEmpty }.joined(separator: ". "))
        recolor()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recolor()
    }

    private func recolor() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            title.font = .systemFont(ofSize: TypeScale.title, weight: TypeScale.emphasis)
            detail.textColor = Palette.textSecondary
            detail.font = .systemFont(ofSize: TypeScale.title)
        }
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let side: CGFloat = 22
        let width = bounds.width - side * 2
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let detailHeight = detail.isHidden ? 0 : ceil(detail.intrinsicContentSize.height)
        let top = ((bounds.height + titleHeight + detailHeight) / 2).rounded()
        title.frame = CGRect(x: side, y: top - titleHeight, width: width, height: titleHeight)
        detail.frame = CGRect(x: side, y: top - titleHeight - detailHeight, width: width, height: detailHeight)
    }
}
