public import AppKit
import CmuxNextDesign
import CmuxNextCompat

/// The Chief pet: a small pixel character over a glass rail, floating over every app and every
/// Space as the references draw it (`cmux-design-references` chief-water-reference: the pet,
/// then the rail under it). It never activates cmux and never takes the keys; a drag anywhere
/// but a tool moves it (the spot is kept per screen, `ChiefPetPlacement`), and a click on the
/// character or the rail's compose runs `onClick`. A right-click (or Control-click) offers
/// Chief Pet Settings… and Hide Chief Pet (`contextMenu()`).
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
    /// The right-click menu's Chief Pet Settings… item.
    public var onSettings: (() -> Void)?
    /// The right-click menu's Hide Chief Pet item.
    public var onHide: (() -> Void)?
    /// Whether Hide Chief Pet can run now (false while `home.chiefPetEnabled` is managed).
    public var hideAllowed: (() -> Bool)?
    let placement: ChiefPetPlacement
    let pet: ChiefPetView
    private var expandTool: ChiefPetTool?
    /// The visible frame of the screen the pet is on (its menu bar and Dock left out); tests give their own.
    var visibleFrame: () -> CGRect? = { nil }
    /// The pet was pulled back on its screen after a screen change (the bubble and reply box take their side again).
    var onKeptOnScreen: (() -> Void)?
    /// The pet was shown, hidden, covered or uncovered (another window, the screen asleep): its frames stop or go on.
    var onVisibilityChange: (() -> Void)?
    /// The didChangeScreenParameters observer's token, kept for the panel's life.
    private var screenObserver: MainActorObservation?

    /// `notifications`: where screen-parameter changes are posted (AppKit posts to `.default`); tests give their own.
    public init(mascot: ChiefPetMascot = .initial, defaults: UserDefaults = .standard, notifications: NotificationCenter = .default) {
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
        // Not hidden with cmux (⌘H, Hide Others): Message the Chief from Any App orders it in without unhiding the app.
        canHide = false
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
        pet.contextMenu = { [weak self] in self?.contextMenu() }
        contentView = pet
        delegate = self
        visibleFrame = { [weak self] in self?.screen?.visibleFrame }
        // A resolution change, or the Dock or menu bar resizing, keeps the screen, so AppKit sends no
        // didChangeScreen; the visible frame still changes under the pet.
        screenObserver = MainActorObservation(NSApplication.didChangeScreenParametersNotification, center: notifications) { [weak self] in
            self?.keepOnScreen()
        }
    }

    /// The pet's right-click menu: its settings (the Chief Settings popover, or Settings), and
    /// Hide Chief Pet, which turns `home.chiefPetEnabled` off as the settings' switch does.
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let settings = NSMenuItem(title: ChiefPetStrings.settings, action: #selector(openSettings), keyEquivalent: "")
        let hide = NSMenuItem(title: ChiefPetStrings.hide, action: #selector(hidePet), keyEquivalent: "")
        for item in [settings, hide] {
            item.target = self
            menu.addItem(item)
        }
        hide.isEnabled = hideAllowed?() ?? true
        return menu
    }

    @objc private func openSettings() { onSettings?() }

    @objc private func hidePet() { onHide?() }

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
        onVisibilityChange?()
    }

    func dismiss() {
        pet.runClip(false)  // hidden: the clip's loop stops
        orderOut(nil)
        onVisibilityChange?()
    }

    /// A screen change (a display unplugged, the pet dragged onto another) keeps it on its screen.
    public func windowDidChangeScreen(_ notification: Notification) {
        keepOnScreen()
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        onVisibilityChange?()
    }

    /// Whether the pet faces right: toward the nearer side of its screen, the side it is docked toward.
    var facesRight: Bool {
        guard let visible = visibleFrame() else { return true }
        return frame.midX >= visible.midX
    }

    /// Pulls the pet fully back on its screen. Not during a drag: AppKit reports the screen change as
    /// the pet crosses onto the next display, and pulling it back then would jump it away from the
    /// pointer until the next move (the drag's end pulls it back, `saveOrigin`).
    func keepOnScreen() {
        guard !pet.isDragging, let visible = visibleFrame() else { return }
        let origin = ChiefPetPlacement.clamped(frame.origin, size: frame.size, in: visible)
        // The screen's middle can move with no move of the pet (another screen, a new resolution):
        // the controller redraws the character's facing either way.
        guard origin != frame.origin else {
            onKeptOnScreen?()
            return
        }
        setFrameOrigin(origin)
        onKeptOnScreen?()
    }

    /// Keeps the spot the pet was dragged to, pulled fully back on its screen.
    func saveOrigin() {
        guard let visible = visibleFrame() else { return }
        let origin = ChiefPetPlacement.clamped(frame.origin, size: frame.size, in: visible)
        if origin != frame.origin { setFrameOrigin(origin) }
        if let screen { placement.save(origin, onDisplay: ChiefPetPlacement.display(screen)) }
    }

    static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}

/// The pet's content: the character, and the rail under it. A press that moves past
/// `ChiefPetPlacement.dragSlop` drags the panel; one on the character that does not is a click.
/// The rail's tools take their own clicks. Clicks work on the first press: the panel is never key.
final class ChiefPetView: NSView, StatusIndicatorConfigClient {
    var onClick: (() -> Void)?
    /// After each step of a drag, with the panel already moved (the notices follow it live).
    var onDragMoved: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// The right-click menu (the panel's `contextMenu()`).
    var contextMenu: (() -> NSMenu?)?
    /// The pointer in screen points; tests drive their own.
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    let rail = ChiefPetRail()
    private let badgeView = ChiefPetBadge()
    /// The pixel character, drawn by a layer so it scales up with whole pixels.
    private let character = ChiefPetCharacter()
    /// The person's upload, drawn instead of `image` while set (``play(_:)``).
    private var clip: ChiefPetClip?
    /// An animated character's frames, over the character's box (hidden for a still character).
    let sprite = ChiefPetSpriteLayer()
    /// Where the press started, in screen points, the panel's origin then, and whether it was on the character.
    private var press: (start: CGPoint, origin: CGPoint, onCharacter: Bool)?
    private var dragging = false
    /// A press is moving the pet now.
    var isDragging: Bool { dragging }

    init(image: NSImage?) {
        super.init(frame: .zero)
        character.wantsLayer = true
        character.layer?.contentsGravity = .resizeAspect
        character.layer?.magnificationFilter = .nearest
        character.layer?.minificationFilter = .trilinear
        character.layer?.addSublayer(sprite.layer)
        addSubview(character)
        addSubview(rail)
        badgeView.isHidden = true
        addSubview(badgeView)
        self.image = image
        character.layer?.contents = image
        character.setAccessibilityElement(true)
        // A button, not an image: the panel never takes the keys, so VoiceOver's press is the only way
        // to the reply box that is not the pointer.
        character.setAccessibilityRole(.button)
        character.setAccessibilityLabel(ChiefPetStrings.accessibilityLabel)
        character.onPress = { [weak self] in self?.onClick?() }
        themedToolTip = ChiefPetStrings.accessibilityLabel
        // Reduce Motion, calm mode and the speed setting reach the clip's loop at once, by the
        // indicators' one broadcast (held weakly: it ends with the view).
        StatusIndicatorAppearance.shared.register(self)
    }

    /// Loops just turned off (or on): the clip stops on its first frame (or moves again).
    func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig) {
        reconcileClip()
    }

    /// Checks the clip's loop against the motion policy now (Reduce Motion, calm mode, the Home switch).
    func reconcileClip() {
        runClip(clipAllowed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var image: NSImage? {
        didSet { if clip == nil { character.layer?.contents = sprite.layer.isHidden ? image : nil } }
    }

    /// Draws `clip` (the person's upload) instead of `image` or an animated character; nil draws the
    /// character again (the controller redraws an animated one). Its first frame shows until
    /// `runClip(_:)` lets it move.
    func play(_ clip: ChiefPetClip?) {
        self.clip = clip
        // An upload covers the character: an animated one's frames stop and hide under it.
        if clip != nil { sprite.show(nil, state: .idle, facingRight: true, moving: false) }
        // No clip: the still `image`, unless an animated character's frames show over the box.
        character.layer?.contents = clip?.frames.first ?? (sprite.layer.isHidden ? image : nil)
        character.layer?.removeAnimation(forKey: "clip")
        clipRuns = false
        runClip(clipAllowed)
    }

    /// Whether the clip may move now (the controller's: the pet on screen and cmux active).
    private var clipAllowed = false
    private var clipRuns = false

    /// Starts a moving clip's loop when `allowed` and loops may run (Reduce Motion, calm mode and the
    /// Home motion switch off them), else removes it and the first frame stays. The loop's one stop and
    /// cleanup: Core Animation runs it in the render server, with no timer here; it is removed when the
    /// pet hides, cmux goes to the back, the upload changes, or loops turn off (``statusIndicatorConfigDidChange(_:)``).
    func runClip(_ allowed: Bool) {
        clipAllowed = allowed
        guard let layer = character.layer else { return }
        let loop = allowed ? clip.flatMap { Motion.home.clipAnimation($0.frames, delays: $0.delays) } : nil
        guard (loop != nil) != clipRuns else { return }
        layer.removeAnimation(forKey: "clip")
        clipRuns = loop != nil
        if let loop { layer.add(loop, forKey: "clip") }
    }

    /// Draws an animated character's `state` (nil: the still `image`), facing right or left, its row
    /// stepping while `moving`. A still character keeps `image` and never moves; an upload (`clip`)
    /// is drawn instead of either.
    func animate(_ animated: ChiefPetSprite?, state: ChiefPetState, facingRight right: Bool, moving: Bool) {
        guard clip == nil else { return }
        sprite.show(animated, state: state, facingRight: right, moving: moving)
        character.layer?.contents = animated == nil ? image : nil
    }

    override func layout() {
        super.layout()
        let size = ChiefPetPanel.characterSize
        character.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - size.height, width: size.width, height: size.height)
        sprite.layer.frame = character.bounds
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

    /// A right-click on the pet opens its menu (AppKit asks here on a right mouse down).
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func mouseDown(with event: NSEvent) {
        // Control-click is a right-click: the menu, never a drag or the reply box.
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            press = nil
            return NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        let local = convert(event.locationInWindow, from: nil)
        press = (pointer(), window?.frame.origin ?? .zero, character.frame.contains(local))
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, let window else { return }
        let point = pointer()
        if !dragging, !ChiefPetPlacement.isDrag(from: press.start, to: point) { return }
        dragging = true
        // Whole points, as the saved spot is: the drop then rounds nothing and the notices stay put.
        window.setFrameOrigin(CGPoint(x: (press.origin.x + point.x - press.start.x).rounded(), y: (press.origin.y + point.y - press.start.y).rounded()))
        onDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil; dragging = false }
        guard let press else { return }
        if dragging { onDragEnded?() } else if press.onCharacter { onClick?() }
    }

    /// Where the character sits in the view.
    var characterFrame: CGRect { character.frame }
    /// What the character's own box draws (the still or an upload frame; nil under an animated character's frames).
    var characterContents: Any? { character.layer?.contents }

    override func resetCursorRects() {
        addCursorRect(character.frame, cursor: .pointingHand)
    }
}

/// The character's view: a VoiceOver press on it is a click on the character.
final class ChiefPetCharacter: NSView {
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}
