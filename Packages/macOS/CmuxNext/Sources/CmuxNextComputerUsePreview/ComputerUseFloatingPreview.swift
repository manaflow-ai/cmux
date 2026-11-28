public import AppKit
import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextSettings
import ImageIO
import QuartzCore
import os

private let logger = Logger(subsystem: "com.cmuxterm.next", category: "computer-use-floating-preview")

/// Computer Use's live preview in a floating panel over every app (`computerUse.floatingPreview`,
/// off by default; prototype). User 2026-11-22: "WHERE IS THE FUCKING PREVIEW OF THE FUCKING RUNNING
/// SITUATION AND THE ABILITY TO DRAG IT AROUND AND FUCKING HIDE IT"; 2026-10-29: "But why can't I click
/// and drag? And why can't I full screen this picture?".
///
/// The panel never takes focus ("you're foregrounding shit"): it is a non-activating
/// ``ComputerUseFloatingPreviewPanel`` that can never become key or main, and it is only ever
/// ordered in with `orderFrontRegardless` (never `makeKeyAndOrderFront`, never `NSApp.activate`).
/// It is dragged by its background anywhere on screen, resized from its edges, grown or shrunk
/// with its expand button, and hidden with its close button or the menu bar's Computer Use menu
/// (Show/Hide Floating Preview). Where it sat and whether the person hid it outlive a relaunch.
///
/// It follows the same daemon `computer-use-preview` events as ``ComputerUsePreviewRouter`` (its
/// own subscriber, so the router is untouched): the newest running session's card shows; a line of
/// another session that is not running leaves it alone; the shown session's card going hides the
/// panel unless the person asked for it from the menu (then it waits, empty, for the next card).
@MainActor
public final class ComputerUseFloatingPreview {
    /// The setting: off, the panel never shows and the menu has no row for it.
    public var enabled = false {
        didSet { if enabled != oldValue { apply() } }
    }

    /// The panel shows now (what the menu's row reads).
    public var isShown: Bool { wantsShown }

    /// What the panel would show: enabled, not hidden by the person, and a card or the person's Show.
    var wantsShown: Bool { enabled && !hiddenByPerson && (card != nil || pinned) }

    /// The card shown, nil when no session's preview is live.
    private(set) var card: Card?
    /// The person hid the panel (close button or menu); kept across launches.
    private(set) var hiddenByPerson: Bool {
        get { defaults.bool(forKey: Self.hiddenKey) }
        set { defaults.set(newValue, forKey: Self.hiddenKey) }
    }
    /// The person asked for the panel from the menu: it stays while no card is live.
    private(set) var pinned = false
    private let defaults: UserDefaults
    private var subscription: UInt64?
    private var following: Task<Void, Never>?
    private(set) var panel: ComputerUseFloatingPreviewPanel?
    /// Keeps the panel's frame where the person left it (the panel's delegate).
    private lazy var frameKeeper = ComputerUseFloatingPreviewFrameKeeper { [weak self] frame in
        self?.defaults.set(NSStringFromRect(frame), forKey: Self.frameKey)
    }

    static let hiddenKey = "cmux.computerUse.floatingPreview.hidden"
    static let frameKey = "cmux.computerUse.floatingPreview.frame"

    /// One preview line's card, as the panel draws it.
    struct Card: Equatable {
        var session: String
        var app: String
        var done: Bool
        /// A `data:image/jpeg;base64,` URL.
        var frame: String
        /// Where the agent acts, as fractions of the frame (0...1), if the worker says.
        var pointer: CGPoint?
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Follows `store`'s `computer-use-preview` events (pushed, never polled), and the setting
    /// through `enabled` (re-read on each change of what it reads, Observation); `menu`'s Computer
    /// Use menu gets its Show/Hide Floating Preview row, and owns the panel's owner from then on.
    public func follow(_ store: DaemonStore, menu: MenuBarExtra, enabled: @escaping @MainActor @Sendable () -> Bool) {
        menu.floatingPreview = MenuBarExtra.FloatingPreview(
            shown: { self.enabled ? self.isShown : nil },
            setShown: { self.setShown($0) })
        following?.cancel()
        // task-owner: replaced by the next follow; lives as long as the App's services
        following = Task { [weak self] in
            for await value in ObservationStream({ enabled() }) {
                guard let self else { return }
                self.enabled = value
            }
        }
        guard subscription == nil else { return }
        subscription = store.sideEvents.subscribe { [weak self] event in
            guard case .unknown(name: "computer-use-preview", let payload) = event else { return }
            self?.take(payload)
        }
    }

    /// Shows (the menu's Show Floating Preview) or hides (Hide, or the panel's close button) the panel.
    public func setShown(_ shown: Bool) {
        hiddenByPerson = !shown
        pinned = shown
        logger.notice("floating preview \(shown ? "shown" : "hidden", privacy: .public) by the person")
        apply()
    }

    func take(_ payload: CmuxNextDaemon.JSONValue) {
        guard case .object(let line) = payload, case .string(let session)? = line["session"] else { return }
        let next: Card? = if case .object(let raw)? = line["card"] { Self.card(raw) } else { nil }
        let running = next.map { !$0.done } ?? false
        // A surface-less panel shows one session: a running card takes it, the shown session's lines
        // change it, and another session's done or gone line leaves it alone.
        guard running || card == nil || card?.session == session else { return }
        card = next
        apply()
    }

    /// The panel's card of a preview line's `card`, nil without a session or a frame.
    static func card(_ raw: [String: CmuxNextDaemon.JSONValue]) -> Card? {
        guard case .string(let session)? = raw["session"], case .string(let frame)? = raw["frame"], frame.hasPrefix("data:image/")
        else { return nil }
        let app: String = if case .string(let app)? = raw["app"] { app } else { "" }
        var pointer: CGPoint?
        if case .object(let p)? = raw["pointer"], case .number(let x)? = p["x"], case .number(let y)? = p["y"] {
            pointer = CGPoint(x: x, y: y)
        }
        return Card(session: session, app: app, done: raw["done"] == .bool(true), frame: frame, pointer: pointer)
    }

    private func apply() {
        guard wantsShown else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        panel.content.show(card)
        // Never makeKeyAndOrderFront or NSApp.activate: the panel must not take focus.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> ComputerUseFloatingPreviewPanel {
        let panel = ComputerUseFloatingPreviewPanel(contentRect: savedFrame() ?? Self.defaultFrame())
        panel.content.onClose = { [weak self] in self?.setShown(false) }
        panel.content.onExpand = { [weak panel] in panel?.toggleExpanded() }
        panel.delegate = frameKeeper
        self.panel = panel
        return panel
    }

    private func savedFrame() -> NSRect? {
        guard let text = defaults.string(forKey: Self.frameKey) else { return nil }
        let rect = NSRectFromString(text)
        guard rect.width >= ComputerUseFloatingPreviewPanel.minWidth,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) else { return nil }
        return rect
    }

    /// The bottom right of the main screen's visible frame, at the panel's resting width.
    private static func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: ComputerUseFloatingPreviewPanel.restingWidth, height: ComputerUseFloatingPreviewPanel.restingWidth * 10 / 16)
        return NSRect(x: visible.maxX - size.width - 24, y: visible.minY + 24, width: size.width, height: size.height)
    }
}

/// Saves the panel's frame each time the person moves or resizes it.
@MainActor
final class ComputerUseFloatingPreviewFrameKeeper: NSObject, NSWindowDelegate {
    private let save: @MainActor (NSRect) -> Void

    init(save: @escaping @MainActor (NSRect) -> Void) {
        self.save = save
    }

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow { save(window.frame) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow { save(window.frame) }
    }
}

/// The floating preview's window: a borderless-looking, non-activating, always-on-top panel on
/// every Space and over full-screen apps, dragged by its background, that can never become key or
/// main, so showing it or clicking it never takes focus from the app the person (or agent) uses.
@MainActor
final class ComputerUseFloatingPreviewPanel: NSPanel {
    static let restingWidth: CGFloat = 360
    static let minWidth: CGFloat = 160
    let content: ComputerUseFloatingPreviewView
    /// The shared overlay glass the picture sits in.
    private let surface: NSView
    private var restingFrame: NSRect?

    init(contentRect: NSRect) {
        let content = ComputerUseFloatingPreviewView()
        self.content = content
        surface = Glass.makeOverlayPanel(content: content) // concentric-allow: the glass is the panel itself, edge to edge
        surface.translatesAutoresizingMaskIntoConstraints = true
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .utilityWindow],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        minSize = NSSize(width: Self.minWidth, height: Self.minWidth * 9 / 16)
        contentView = surface
        content.onAspect = { [weak self] aspect in self?.fit(aspect: aspect) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The frame's height follows the picture's aspect at the panel's width (the top edge stays).
    private func fit(aspect: CGFloat) {
        guard aspect > 0 else { return }
        contentAspectRatio = NSSize(width: 1, height: aspect)
        var rect = frame
        let height = (rect.width * aspect).rounded()
        guard abs(height - rect.height) > 0.5 else { return }
        rect.origin.y += rect.height - height
        rect.size.height = height
        setFrame(rect, display: true)
    }

    /// "why can't I full screen this picture?": grows to most of its screen, or back.
    func toggleExpanded() {
        if let resting = restingFrame {
            restingFrame = nil
            setFrame(resting, display: true)
            return
        }
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        restingFrame = frame
        let aspect = frame.width > 0 ? frame.height / frame.width : 10 / 16
        var size = NSSize(width: visible.width * 0.9, height: visible.width * 0.9 * aspect)
        if size.height > visible.height * 0.9 { size = NSSize(width: visible.height * 0.9 / aspect, height: visible.height * 0.9) }
        setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height),
                 display: true)
    }
}

/// The panel's picture: the newest frame, aspect-fit, with the agent's pointer, a close and an
/// expand button. A new frame shows once decoded (off the main thread), so it never blanks.
@MainActor
final class ComputerUseFloatingPreviewView: NSView {
    var onClose: (() -> Void)?
    var onExpand: (() -> Void)?
    var onAspect: ((CGFloat) -> Void)?
    private let frameLayer = CALayer()
    private let pointerLayer = CALayer()
    private let closeButton = ComputerUseFloatingPreviewButton(symbol: "xmark")
    private let expandButton = ComputerUseFloatingPreviewButton(symbol: "arrow.up.left.and.arrow.down.right")
    private var card: ComputerUseFloatingPreview.Card?
    private var decoding: String?
    private var aspect: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.cornerRadius = Metrics.panelCornerRadius // radius-allow: the picture's corner follows the panel glass, not a button
        frameLayer.masksToBounds = true
        layer?.addSublayer(frameLayer)
        pointerLayer.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        pointerLayer.cornerRadius = 6 // radius-allow: the agent pointer is a 12 pt round dot, not a button
        pointerLayer.backgroundColor = NSColor.systemBlue.cgColor
        // The dot's halo is the theme's window color, so it reads against any screenshot and follows the theme (rule R6).
        pointerLayer.borderColor = Palette.windowBackground.cgColor
        pointerLayer.borderWidth = 2
        pointerLayer.isHidden = true
        frameLayer.addSublayer(pointerLayer)
        closeButton.target = self
        closeButton.action = #selector(close)
        expandButton.target = self
        expandButton.action = #selector(expand)
        addSubview(closeButton)
        addSubview(expandButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Dragging anywhere but a button moves the panel.
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func close() { onClose?() }
    @objc private func expand() { onExpand?() }

    func show(_ card: ComputerUseFloatingPreview.Card?) {
        let previous = self.card
        self.card = card
        guard let card else {
            frameLayer.contents = nil
            pointerLayer.isHidden = true
            decoding = nil
            return
        }
        if card.frame != previous?.frame { decode(card.frame) }
        layoutPointer()
    }

    private func decode(_ url: String) {
        decoding = url
        // task-owner: one frame's decode; a newer frame or a hide supersedes it (`decoding`).
        Task { [weak self] in
            let image = await Self.decoded(url)
            guard let self, self.decoding == url, let image else { return }
            self.decoding = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.frameLayer.contents = image
            CATransaction.commit()
            let aspect = image.width > 0 ? CGFloat(image.height) / CGFloat(image.width) : 0
            if abs(aspect - self.aspect) > 0.001 {
                self.aspect = aspect
                self.onAspect?(aspect)
            }
            self.layoutPointer()
        }
    }

    @concurrent nonisolated static func decoded(_ url: String) async -> CGImage? {
        guard let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        CATransaction.commit()
        let side: CGFloat = 22
        closeButton.frame = NSRect(x: 8, y: bounds.maxY - side - 8, width: side, height: side) // concentric-allow: round buttons over the picture, like the window's traffic lights
        expandButton.frame = NSRect(x: bounds.maxX - side - 8, y: bounds.maxY - side - 8, width: side, height: side)
        layoutPointer()
    }

    /// The pointer dot at the card's pointer, inside the aspect-fit picture.
    private func layoutPointer() {
        guard let pointer = card?.pointer, frameLayer.contents != nil, aspect > 0 else {
            pointerLayer.isHidden = true
            return
        }
        let box = frameLayer.bounds
        let width = min(box.width, box.height / aspect)
        let picture = CGRect(x: box.midX - width / 2, y: box.midY - width * aspect / 2, width: width, height: width * aspect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointerLayer.position = CGPoint(x: picture.minX + pointer.x * picture.width, y: picture.maxY - pointer.y * picture.height)
        pointerLayer.isHidden = false
        CATransaction.commit()
    }
}

/// A round button over the picture that works on the first click of a panel that is never key.
@MainActor
final class ComputerUseFloatingPreviewButton: NSButton {
    init(symbol: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .circular
        contentTintColor = .white
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = Metrics.buttonCornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
