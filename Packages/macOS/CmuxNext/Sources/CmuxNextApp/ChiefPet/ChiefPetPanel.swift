import AppKit
import CmuxNextDesign

/// The Chief pet: a small character floating over every app and every
/// Space. It never activates cmux and never takes the keys; a drag moves it
/// (the spot is kept per screen, `ChiefPetPlacement`), and a click runs
/// `onClick`.
final class ChiefPetPanel: NSPanel, NSWindowDelegate {
    static let accessibilityID = "cmux.chiefPet"
    /// The bundled Chief (256 x 309) at the size Leo's floating-pet references show it.
    static let petSize = CGSize(width: 64, height: 77)
    /// The Chief's bundled avatar, the character the references float over the desktop.
    static let defaultImage = Bundle.module.image(forResource: "ChiefAvatar")

    /// A click that was not a drag.
    var onClick: (() -> Void)?
    let placement: ChiefPetPlacement
    let pet: ChiefPetView

    init(image: NSImage?, defaults: UserDefaults = .standard) {
        placement = ChiefPetPlacement(defaults: defaults)
        pet = ChiefPetView(image: image)
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
        pet.onDragEnded = { [weak self] in self?.saveOrigin() }
        contentView = pet
        delegate = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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
    func windowDidChangeScreen(_ notification: Notification) {
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

/// The pet's character. A press that moves past `ChiefPetPlacement.dragSlop`
/// drags the panel; one that does not is a click. Clicks work on the first
/// press: the panel is never key.
final class ChiefPetView: NSView {
    var onClick: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// The pointer in screen points; tests drive their own.
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    private let imageView = NSImageView()
    /// Where the press started, in screen points, and the panel's origin then.
    private var press: (start: CGPoint, origin: CGPoint)?
    private var dragging = false

    init(image: NSImage?) {
        super.init(frame: .zero)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(ChiefPetStrings.accessibilityLabel)
        toolTip = ChiefPetStrings.accessibilityLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var image: NSImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The pet takes every press on it; the image view never sees one.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDown(with event: NSEvent) {
        press = (pointer(), window?.frame.origin ?? .zero)
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
        guard press != nil else { return }
        if dragging { onDragEnded?() } else { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
