public import AppKit
public import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// A floating web card host (first user: the server cards, design/server-cards.md): a borderless,
/// non-activating glass panel near the top center of the cmux window, on every Space and over full
/// screen, that shows one warm first-party React page (any descriptor; `cmux.server-cards`), one card per route
/// (`#/pair-invite`, ...). The page and its providers are made once and kept: a later open swaps
/// the route, never loads a page.
///
/// The page drives its own size and close (`cmux.card.*`, ``WebCardHostProvider``):
/// - `cmux.card.resize {card, height, width?}` (CSS px): the page measured its content; the panel
///   grows or shrinks downward, keeping its top edge where the person saw it (with its own footer
///   under the page while a click-only control shows);
/// - `cmux.card.close {card}`: the card's Cancel or Done ran; the panel hides;
/// - stream `cmux.card.commands`: `{command: "cancel"}` when Escape reaches the panel outside the
///   page (the card runs its own Cancel).
///
/// A card plugs in as a ``WebCard``: a page provider for its own `cmux.<card>.` prefix that hears
/// its opening and closing. An action only the person's own click may take (approve, allow) is a
/// native button, not a page control (``PersonControl``): the card names it
/// (``setPersonControl(_:card:)``), the page only places it, and its click reaches the card as
/// ``WebCard/personPressed()``. A grant needs a control the page cannot press, name or move a click onto.
@MainActor
public final class WebCardPanel: NSPanel {
    /// The gap between the window's top edge and the card's.
    public static let topInset: CGFloat = 56
    /// How long an opening waits for the page's first size before it shows anyway.
    static let firstSizeWait: Duration = .milliseconds(400)

    /// The page floats on the panel's glass: a Chromium page cannot be transparent. A first click
    /// acts at once, like the native card's buttons.
    public static let engineOptions = PageEngineOptions(requiresWebKit: .transparentOverlay, acceptsFirstMouse: true)

    public let page: PageWebView
    /// The cards the page shows, by route.
    public let cards: [String: any WebCard]
    private let host: WebCardHostProvider
    private let glass: GlassPanelView
    /// The glass's content: the page above, the native footer under it while a control shows.
    private let surface = WebCardSurface()
    /// The card the panel shows (its route without `#/`), nil before the first opening.
    public private(set) var card: String?
    /// The system's double-click interval, read at each click (tests stand in another).
    var doubleClickInterval: @MainActor () -> TimeInterval = { NSEvent.doubleClickInterval }
    /// SECURITY: reads the person's own click on the native control from the panel's dispatch
    /// (``CmuxDialogPersonClick``): a click begun within the system's double-click interval, and at
    /// least ``steadyControl``, of the control showing, moving or the card drawing anew is not taken
    /// (worked out at each click, so a changed setting applies at once).
    private(set) lazy var personClick = CmuxDialogPersonClick { [weak self] in
        max(self?.doubleClickInterval() ?? NSEvent.doubleClickInterval, WebCardPanel.steadyControl)
    }
    /// Whether an event is the person's own input (the app's strict source check); with none set, none is.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool {
        get { personClick.isPersonEvent }
        set { personClick.isPersonEvent = newValue }
    }
    /// Whether the panel is key for the person's click (tests stand in for a key panel).
    var isKeyForPerson: @MainActor (WebCardPanel) -> Bool = { $0.isKeyWindow }
    /// The last size each card's page reported, in points.
    private var sizes: [String: NSSize] = [:]
    /// An opening waiting for its card's first size: where and how it shows.
    private var pending: (card: String, parent: NSRect?, visible: NSRect, intent: WindowActivation.Intent)?
    private let pendingTimeout = DemandTimer(owner: "web-card-first-size")
    /// Each card's click-only control, as the card last named it.
    private var controls: [String: PersonControl] = [:]
    /// The native click-only control, laid out by the panel in its footer.
    var personButton: ThemedBezelButton { surface.button }

    /// - Parameters:
    ///   - descriptor: The card page's descriptor; its namespaces must include `cmux.card.` and each card's prefix.
    ///   - cards: The cards, each served at its own ``WebCard/prefix``.
    ///   - routes: Shared providers (such as `cmux.app.`).
    ///   - width: The width before the page reports its own.
    ///   - overlayProcess: The app's overlay pages' shared web content process (``PageOverlayProcess``); nil
    ///     gives the page its own.
    public init?(descriptor: PageDescriptor, cards: [any WebCard], routes: [PageRoute] = [], width: CGFloat = 460,
                 overlayProcess: PageOverlayProcess? = nil) {
        let host = WebCardHostProvider()
        let routes = routes + cards.map { PageRoute(prefix: $0.prefix, provider: $0) }
        guard let page = PageWebView(descriptor: descriptor, routes: routes + [PageRoute(prefix: WebCardHostProvider.prefix, provider: host)],
                                     options: Self.engineOptions, overlayProcess: overlayProcess) else { return nil }
        self.page = page
        self.host = host
        self.cards = Dictionary(cards.map { ($0.card, $0) }, uniquingKeysWith: { first, _ in first })
        // The page, and under it the native footer for a click-only control, on the panel's glass.
        surface.page = page
        glass = Glass.makePanel(content: surface, style: .regular, cornerRadius: 14)
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: width, height: 240)),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.webCard")
        glass.autoresizingMask = [.width, .height]
        contentView = glass
        host.panel = self
        for card in cards { card.host = self }
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    /// Shows `card` over `window` (the cmux window it belongs to; nil uses the screen's top).
    /// `takeKeys` is true when a person opened it by hand. A card the page has measured before
    /// shows at once at that size; a first opening shows when the page reports its size (or after
    /// ``firstSizeWait``), so the card never draws at a wrong height and then jumps.
    public func present(card: String, over window: NSWindow?, takeKeys: Bool) {
        let open = isVisible || pending != nil
        let again = open && self.card == card
        // Another card open closes first (its session ends): the new one never shows over its
        // content or at its height while the page measures the new route.
        if let shown = self.card, shown != card, open { orderOut(nil) }
        self.card = card
        cards[card]?.opened(again: again)
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
        page.open(route: "/" + card)
        let screen = window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let intent: WindowActivation.Intent = takeKeys ? .raise : .bringForward
        if let size = sizes[card] {
            show(size: panelSize(size), parent: window?.frame, visible: visible, intent: intent)
            return
        }
        pending = (card, window?.frame, visible, intent)
        // One deadline per opening; the page's first size or a new opening ends it.
        pendingTimeout.schedule(after: Self.firstSizeWait) { @MainActor [weak self] in
            guard let self, let pending = self.pending, pending.card == card else { return }
            self.show(size: self.frame.size, parent: pending.parent, visible: pending.visible, intent: pending.intent)
        }
    }

    /// Hides the card (its owner closed it).
    public func dismiss() {
        orderOut(nil)
    }

    /// Horizontally centered on `parent`, its top ``topInset`` below the parent's top, kept inside
    /// `visible`; with no parent, the top center of `visible`.
    public static func placement(size: CGSize, over parent: NSRect?, in visible: NSRect) -> NSRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let anchor = parent ?? visible
        let x = min(max(anchor.midX - width / 2, visible.minX), visible.maxX - width)
        let top = min(anchor.maxY, visible.maxY) - topInset
        let y = min(max(top - height, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - The person's click

    /// The card drew anew (its provider's state changed): a click begun within a double-click
    /// interval from now is not taken as aimed at it (a machine arrived and Confirm appeared under
    /// a pointer aimed at what was there before).
    public func rearm(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        personClick.shown(at: uptime)
    }

    /// Names the card's click-only control (nil: none shows). While it shows, the panel lays it out
    /// in its own footer under the page; the page's size covers only the content above.
    public func setPersonControl(_ control: PersonControl?, card: String) {
        guard controls[card] != control else { return }
        controls[card] = control
        guard card == self.card else { return }
        placePersonControl()
        if isVisible, let size = sizes[card] { fit(panelSize(size)) }
    }

    override public func sendEvent(_ event: NSEvent) {
        dispatch(event) { super.sendEvent(event) }
    }

    /// SECURITY: runs `body` (the panel's own dispatch of `event`); when `event` ended the person's
    /// own left click on the enabled native control (``CmuxDialogPersonClick``: from the HID system,
    /// down and up on the button, not a key, an Accessibility press, a posted event or a script; held
    /// through a mouse-up AppKit dispatches on its own), on the key panel, the card hears it once.
    func dispatch(_ event: NSEvent, _ body: () -> Void) {
        // A move the panel's own sizing did not report (a drag, any other frame change) still
        // counts: Confirm somewhere new on screen rearms first, so that click is not taken.
        if event.type == .leftMouseDown, hasFooter, controlScreenRect != currentControlScreenRect { controlMoved() }
        guard personClick.dispatch(event, allow: { [weak self] in self?.enabledControl }, in: windowNumber, body),
              isKeyForPerson(self), let card else { return }
        cards[card]?.personPressed()
    }

    /// The native control while it shows enabled for the shown card.
    private var enabledControl: NSControl? {
        guard let card, controls[card]?.isEnabled == true, !personButton.isHidden, isControlWhole else { return nil }
        return personButton
    }

    /// SECURITY: whether the control shows whole: its full fitting size, inside the card.
    private var isControlWhole: Bool {
        let frame = personButton.convert(personButton.bounds, to: glass)
        let fitting = personButton.fittingSize
        return glass.bounds.contains(frame) && frame.width >= fitting.width && frame.height >= fitting.height
    }

    /// Where the control was on screen when the guard last rearmed for it.
    private var controlScreenRect: NSRect?
    private var currentControlScreenRect: NSRect {
        convertToScreen(personButton.convert(personButton.bounds, to: nil))
    }

    /// Confirm moved on screen (or appeared): a click begun before it has stayed put is not taken.
    private func controlMoved() {
        controlScreenRect = currentControlScreenRect
        rearm()
    }

    private func frameChanged() {
        guard hasFooter else { return }
        glass.layoutSubtreeIfNeeded()
        controlMoved()
    }

    /// The smallest content while a control shows: the footer and the control at full size.
    private var minimumContent: NSSize {
        NSSize(width: personButton.fittingSize.width + 2 * WebCardSurface.inset, height: surface.footerHeight)
    }


    /// Whether a control shows in the footer for the shown card.
    private var hasFooter: Bool { card.flatMap { controls[$0] } != nil }

    /// Shows the shown card's control in the footer (its title and state), or hides the footer.
    private func placePersonControl() {
        let control = card.flatMap { controls[$0] }
        surface.show(control)
        if control != nil {
            contentMinSize = minimumContent
            controlMoved()
        } else {
            contentMinSize = .zero
            controlScreenRect = nil
            rearm()
        }
    }

    /// SECURITY: the panel's size for a page content size: the footer under it while a control
    /// shows, and never smaller than the footer with the control at full size, whatever the page asks.
    private func panelSize(_ content: NSSize) -> NSSize {
        guard hasFooter else { return content }
        return NSSize(width: max(content.width, minimumContent.width), height: content.height + surface.footerHeight)
    }

    /// How long the native control stays put (and the card unchanged) before a click on it counts.
    static let steadyControl: TimeInterval = 0.5

    // MARK: - The page's requests

    /// Escape outside the page: the card runs its own Cancel; with no page listening, the panel hides.
    override public func cancelOperation(_ sender: Any?) {
        if !host.send(["command": "cancel"]) { orderOut(nil) }
    }

    /// Closing the card any other way closes its provider's session too.
    override public func orderOut(_ sender: Any?) {
        // A card still waiting for its first size is open too: its session ends with it.
        let shown = isVisible || pending != nil ? card : nil
        pending = nil
        pendingTimeout.cancel()
        super.orderOut(sender)
        if let shown { finish(shown) }
    }

    /// `cmux.card.resize`: `width` and `height` are in CSS px; the page is zoomed (the interface
    /// scale), so one CSS px is `pageZoom * magnification` points.
    func pageResized(card: String, width: CGFloat?, height: CGFloat) {
        let zoom = page.webKitView.pageZoom * page.webKitView.magnification
        let size = NSSize(width: ceil((width ?? frame.width / zoom) * zoom), height: ceil(height * zoom))
        guard size.height > 0 else { return }
        sizes[card] = size
        guard card == self.card else { return }
        if let pending, pending.card == card {
            show(size: panelSize(size), parent: pending.parent, visible: pending.visible, intent: pending.intent)
        } else if isVisible {
            fit(panelSize(size))
        }
    }

    /// `cmux.card.close`: the card's Cancel or Done.
    func pageClosed(card: String) {
        guard card == self.card else { return }
        orderOut(nil)
    }

    private func show(size: NSSize, parent: NSRect?, visible: NSRect, intent: WindowActivation.Intent) {
        pending = nil
        pendingTimeout.cancel()
        setFrame(Self.placement(size: size, over: parent, in: visible), display: false)
        WindowActivation.show(self, intent)
        if intent == .raise { page.focusPage() }
        placePersonControl()
        frameChanged()
    }

    /// Grows or shrinks downward, keeping the top edge where the person saw it.
    private func fit(_ size: NSSize) {
        guard abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
        // Confirm moved on screen with the panel.
        frameChanged()
    }

    private func finish(_ card: String) {
        surface.show(nil)
        cards[card]?.closed()
    }
}

/// The panel's content: the page, and under it, while a click-only control shows, a native footer
/// with that control at its own size at the trailing edge. The page never places the control.
@MainActor
final class WebCardSurface: NSView {
    /// The native click-only control (Confirm, Try Again).
    let button = ThemedBezelButton(frame: .zero)
    private let footer = NSView()
    var page: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let page { addSubview(page, positioned: .below, relativeTo: footer) }
            needsLayout = true
        }
    }

    /// Space around the control in the footer.
    static let inset: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        footer.isHidden = true
        // No action: the grant comes from the panel's dispatch of the person's click, never the button's.
        button.refusesFirstResponder = true
        button.setAccessibilityIdentifier("cmux.webCard.personControl")
        footer.addSubview(button)
        addSubview(footer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The footer's height: the control at its own height with the inset above and below.
    var footerHeight: CGFloat { button.fittingSize.height + 2 * Self.inset }

    /// Shows `control` in the footer, or hides the footer.
    func show(_ control: PersonControl?) {
        if let control {
            if button.title != control.title { button.title = control.title }
            button.isEnabled = control.isEnabled
        }
        footer.isHidden = control == nil
        button.isHidden = control == nil
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let footerHeight = footer.isHidden ? 0 : footerHeight
        page?.frame = NSRect(x: 0, y: footerHeight, width: bounds.width, height: max(bounds.height - footerHeight, 0))
        footer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: footerHeight)
        let size = button.fittingSize
        button.frame = NSRect(x: footer.bounds.maxX - Self.inset - size.width, y: Self.inset, width: size.width, height: size.height)
    }
}

/// A card's click-only control (Confirm, Try Again): its title and whether it can be pressed. The
/// card names it; the panel lays it out natively in its own footer under the page.
public struct PersonControl: Equatable, Sendable {
    public var title: String
    public var isEnabled: Bool

    public init(title: String, isEnabled: Bool) {
        self.title = title
        self.isEnabled = isEnabled
    }
}

/// One card of the shared card page: a page provider for the card's own ops (`cmux.<card>.status`,
/// the stream `cmux.<card>.changes`, its actions) that hears when its panel opens and closes it.
@MainActor
public protocol WebCard: PageProvider {
    /// The card's route in the page (`pair-invite` shows `#/pair-invite`).
    var card: String { get }
    /// The prefix of the card's ops (`cmux.pairInvite.`).
    var prefix: String { get }
    /// The panel that shows the card (the panel sets it): ``WebCardPanel/setPersonControl(_:card:)`` and ``WebCardPanel/rearm(at:)``.
    var host: WebCardPanel? { get set }
    /// The card opens; `again` when it already showed (a live session may stay).
    func opened(again: Bool)
    /// The card closed any way (Cancel, Done, Escape, another card, its owner): its session ends.
    func closed()
    /// The person clicked the card's native click-only control (``PersonControl``).
    func personPressed()
}

public extension WebCard {
    func personPressed() {}
}

/// `cmux.card.*`: the card page's size and close, and the panel's commands to it.
@MainActor
final class WebCardHostProvider: PageProvider {
    static let prefix = "cmux.card."
    static let resizeOp = "cmux.card.resize"
    static let closeOp = "cmux.card.close"
    static let commandsStream = "cmux.card.commands"

    weak var panel: WebCardPanel?
    private var listeners: [Int: @MainActor (JSONValue) -> Void] = [:]
    private var nextListener = 0

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let card = params["card"]?.stringValue, !card.isEmpty else { throw PageError.invalidParams("card is required") }
        switch op {
        case Self.resizeOp:
            guard let height = params["height"]?.doubleValue, height.isFinite else { throw PageError.invalidParams("height is required") }
            let width = params["width"]?.doubleValue.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil }
            panel?.pageResized(card: card, width: width, height: CGFloat(height))
        case Self.closeOp:
            panel?.pageClosed(card: card)
        default:
            throw PageError.unknownOp(op)
        }
        return .null
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.commandsStream else { throw PageError.unknownOp(stream) }
        let id = nextListener
        nextListener += 1
        listeners[id] = onEvent
        return PageSubscription { [weak self] in _ = self?.listeners.removeValue(forKey: id) }
    }

    /// Sends one command to the page; false when no page listens.
    @discardableResult
    func send(_ command: JSONValue) -> Bool {
        for listener in listeners.values { listener(command) }
        return !listeners.isEmpty
    }
}
