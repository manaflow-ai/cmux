public import AppKit
import CmuxNextDesign

/// The Chief pet: a small pixel character over a glass rail, floating over every app and every
/// Space as the references draw it (`cmux-design-references` chief-water-reference: the pet,
/// then the rail under it). It never activates cmux and never takes the keys; a drag anywhere
/// but a tool moves it (the spot is kept per screen, `ChiefPetPlacement`), and a click on the
/// character or the rail's compose runs `onClick`.
public final class ChiefPetPanel: NSPanel, NSWindowDelegate {
    public static let accessibilityID = "cmux.chiefPet"
    /// The character's box and the panel's: the reference's pet is 60 x 80 pt over a 40 pt rail,
    /// 8 pt apart (chief-water-reference, a @2x capture); the pixel mascots are about square,
    /// so their box is wider for the same weight.
    static let characterSize = CGSize(width: 88, height: 80)
    static let gap: CGFloat = 8
    public static let petSize = CGSize(width: 136, height: characterSize.height + gap + ChiefPetRail.height)

    /// A click on the character, or the rail's compose.
    public var onClick: (() -> Void)?
    /// The rail's chevron.
    public var onExpand: (() -> Void)?
    let placement: ChiefPetPlacement
    let pet: ChiefPetView
    private var expandTool: ChiefPetTool?

    public init(mascot: ChiefPetMascot = .initial, defaults: UserDefaults = .standard) {
        placement = ChiefPetPlacement(defaults: defaults)
        pet = ChiefPetView(image: mascot.image)
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.petSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        // The character's PNG carries its own soft edge; a window shadow would box it.
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
        pet.frame = NSRect(origin: .zero, size: Self.petSize)
        pet.autoresizingMask = [.width, .height]
        pet.onClick = { [weak self] in self?.onClick?() }
        pet.rail.addTool(.actionEdit, label: ChiefPetStrings.compose) { [weak self] in self?.onClick?() }
        expandTool = pet.rail.addTool(.disclosureCollapsed, label: ChiefPetStrings.expand, turned: 90) { [weak self] in self?.onExpand?() }
        pet.onDragEnded = { [weak self] in self?.saveOrigin() }
        contentView = pet
        delegate = self
    }

    /// The chevron points down while the notices are unfolded.
    func setExpanded(_ expanded: Bool) {
        expandTool?.turn(to: expanded ? -90 : 90)
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    /// Orders the pet in on the screen under the pointer, where it was left there.
    func present() {
        if !isVisible, let screen = Self.screenUnderPointer() {
            let saved = placement.origin(onDisplay: ChiefPetPlacement.display(screen))
            setFrame(ChiefPetPlacement.frame(saved: saved, size: Self.petSize, in: screen.visibleFrame), display: false)
        }
        // Never key, never activating: it shows over the frontmost app and leaves it in front.
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }

    /// A screen change (resolution, a display unplugged) keeps it on its screen.
    public func windowDidChangeScreen(_ notification: Notification) {
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(ChiefPetPlacement.clamped(frame.origin, size: frame.size, in: visible))
    }

    /// Keeps the spot the pet was dragged to, pulled fully back on its screen.
    func saveOrigin() {
        guard let screen else { return }
        let origin = ChiefPetPlacement.clamped(frame.origin, size: frame.size, in: screen.visibleFrame)
        if origin != frame.origin { setFrameOrigin(origin) }
        placement.save(origin, onDisplay: ChiefPetPlacement.display(screen))
    }

    static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}

/// The pet's content: the character, and the rail under it. A press that moves past
/// `ChiefPetPlacement.dragSlop` drags the panel; one on the character that does not is a click.
/// The rail's tools take their own clicks. Clicks work on the first press: the panel is never key.
final class ChiefPetView: NSView {
    var onClick: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// The pointer in screen points; tests drive their own.
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    let rail = ChiefPetRail()
    private let badgeView = ChiefPetBadge()
    /// The pixel character, drawn by a layer so it scales up with whole pixels.
    private let character = NSView()
    /// Where the press started, in screen points, the panel's origin then, and whether it was on the character.
    private var press: (start: CGPoint, origin: CGPoint, onCharacter: Bool)?
    private var dragging = false

    init(image: NSImage?) {
        super.init(frame: .zero)
        character.wantsLayer = true
        character.layer?.contentsGravity = .resizeAspect
        character.layer?.magnificationFilter = .nearest
        character.layer?.minificationFilter = .trilinear
        addSubview(character)
        addSubview(rail)
        badgeView.isHidden = true
        addSubview(badgeView)
        self.image = image
        character.layer?.contents = image
        character.setAccessibilityElement(true)
        character.setAccessibilityRole(.image)
        character.setAccessibilityLabel(ChiefPetStrings.accessibilityLabel)
        toolTip = ChiefPetStrings.accessibilityLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var image: NSImage? {
        didSet { character.layer?.contents = image }
    }

    override func layout() {
        super.layout()
        let size = ChiefPetPanel.characterSize
        character.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - size.height, width: size.width, height: size.height)
        let width = rail.width
        rail.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: 0, width: width, height: ChiefPetRail.height)
        let badge = badgeView.fittingSize
        badgeView.frame = CGRect(x: character.frame.maxX - badge.width, y: character.frame.maxY - badge.height, width: badge.width, height: badge.height)
    }

    /// Notices that wait for the user, on a small badge at the character's top right; 0 hides it.
    var badge: Int = 0 {
        didSet {
            guard badge != oldValue else { return }
            badgeView.count = badge
            badgeView.isHidden = badge == 0
            needsLayout = true
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A tool takes its own press; anywhere else the pet takes it (a drag, or a click on the character).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        if let hit = super.hitTest(point), hit is NSButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        press = (pointer(), window?.frame.origin ?? .zero, character.frame.contains(local))
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, let window else { return }
        let point = pointer()
        if !dragging, !ChiefPetPlacement.isDrag(from: press.start, to: point) { return }
        dragging = true
        window.setFrameOrigin(CGPoint(x: press.origin.x + point.x - press.start.x, y: press.origin.y + point.y - press.start.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil; dragging = false }
        guard let press else { return }
        if dragging { onDragEnded?() } else if press.onCharacter { onClick?() }
    }

    /// Where the character sits in the view.
    var characterFrame: CGRect { character.frame }

    override func resetCursorRects() {
        addCursorRect(character.frame, cursor: .pointingHand)
    }
}
