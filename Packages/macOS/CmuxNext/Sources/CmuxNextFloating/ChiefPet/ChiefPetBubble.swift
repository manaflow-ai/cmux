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
        // Not hidden with cmux (⌘H, Hide Others): Message the Chief from Any App orders it in without unhiding the app.
        canHide = false
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

    /// Toward the quadrant of the screen with room (Leo 2026-10-20): on the right half the frame's
    /// trailing edge lines up with the pet's and it extends left, on the left half its leading
    /// edge does and it extends right; on the lower half it sits `gap` above the pet, on the upper
    /// half `gap` below it. Then kept fully on screen. The reply box takes the same place.
    static func frame(height: CGFloat, over pet: CGRect, in visible: CGRect, width: CGFloat = ChiefPetBubblePanel.width,
                      gap: CGFloat = ChiefPetBubblePanel.gap) -> CGRect {
        let towardLeft = pet.midX > visible.midX
        let below = pet.midY > visible.midY
        let x = towardLeft ? pet.maxX - width : pet.minX
        let y = below ? pet.minY - gap - height : pet.maxY + gap
        let size = CGSize(width: width, height: height)
        return CGRect(origin: ChiefPetPlacement.clamped(CGPoint(x: x, y: y), size: size, in: visible), size: size)
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
            let text = expanded || index == 0
            capsule.show(notices[index], text: text)
            // VoiceOver reads what a click can open: folded, the front notice; unfolded, each one.
            capsule.setAccessibilityElement(text)
            capsule.onPress = { [weak self] in self?.onOpen?(index) }
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

/// One notice: a glass capsule with the title in bold and one muted line under it, no status
/// glyph, as the references draw it. The glass is the toasts' neutral glass (``FloatingGlassStyle/toast``):
/// a gray veil and rim over the glass, so the text reads over any page behind it while the capsule stays
/// glass. Bare glass let a web page's headline show through the notice, and glass is never made opaque
/// to fix that (Leo 2026-10-20: "I hate opaque").
final class ChiefPetCapsule: NSView {
    /// A VoiceOver press: opens this notice, as a click on it does.
    var onPress: (() -> Void)?
    let surface: OverlaySurfaceView
    private let title = ChromeLabel(labelWithString: "")
    private let detail = ChromeLabel(labelWithString: "")

    override init(frame: NSRect) {
        let radius = ChiefPetBubblePanel.pillHeight / 2
        // The solid surface under Reduce Transparency, followed live.
        surface = Glass.makeOverlayPanel(cornerRadius: radius, tone: .neutralGlass(.toast))
        // The capsule is the whole content of a clear window: the blur before macOS 26 samples what is behind it.
        surface.samplesBehindWindow = true
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

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

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
