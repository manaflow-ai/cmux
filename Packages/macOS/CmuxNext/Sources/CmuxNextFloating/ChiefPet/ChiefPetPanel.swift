public import AppKit
import CmuxNextDesign

/// The Chief pet: a small pixel character over a glass rail, floating over every app and every
/// Space as the references draw it (`cmux-design-references` chief-water-reference: the pet,
/// then the rail under it). It never activates cmux and never takes the keys; a drag anywhere
/// but a tool moves it (the spot is kept per screen, `ChiefPetPlacement`), and a click on the
/// character or the rail's compose runs `onClick`.
public final class ChiefPetPanel: NSPanel, NSWindowDelegate {
    public static let accessibilityID = "cmux.chiefPet"
    /// The character's box and the panel's: the references' pet is about 62 x 80 pt over a
    /// 40 pt rail, 8 pt apart; the pixel mascots are a little wider than tall.
    static let characterSize = CGSize(width: 72, height: 66)
    static let gap: CGFloat = 8
    public static let petSize = CGSize(width: 96, height: characterSize.height + gap + ChiefPetRail.height)

    /// A click that was not a drag.
    public var onClick: (() -> Void)?
    let placement: ChiefPetPlacement
    let pet: ChiefPetView

    public init(mascot: ChiefPetMascot = .standard, defaults: UserDefaults = .standard) {
        placement = ChiefPetPlacement(defaults: defaults)
        pet = ChiefPetView(image: mascot.image)
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.petSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        // The character's PNG carries its own soft edge; a window shadow would box it.
        hasShadow = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setAccessibilityIdentifier(Self.accessibilityID)
        pet.frame = NSRect(origin: .zero, size: Self.petSize)
        pet.autoresizingMask = [.width, .height]
        pet.onClick = { [weak self] in self?.onClick?() }
        pet.rail.addTool(.actionEdit, label: ChiefPetStrings.compose) { [weak self] in self?.onClick?() }
        pet.onDragEnded = { [weak self] in self?.saveOrigin() }
        contentView = pet
        delegate = self
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

    private func saveOrigin() {
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
        addSubview(character)
        addSubview(rail)
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
