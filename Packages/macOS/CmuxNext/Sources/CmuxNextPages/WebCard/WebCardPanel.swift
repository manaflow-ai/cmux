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
/// - `cmux.card.resize {card, height, width?, guard?}` (CSS px): the page measured its content; the
///   panel grows or shrinks downward, keeping its top edge where the person saw it. `guard` is the
///   slot the page leaves for the card's click-only control (Confirm), where the panel draws it;
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
    /// The glass's content: the page edge to edge, the native control over it.
    private let surface = NSView()
    /// The card the panel shows (its route without `#/`), nil before the first opening.
    public private(set) var card: String?
    /// Whether an event is the person's own input (the app's strict source check); with none set, none is.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool = { _ in false }
    /// The last size each card's page reported, in points.
    private var sizes: [String: NSSize] = [:]
    /// An opening waiting for its card's first size: where and how it shows.
    private var pending: (card: String, parent: NSRect?, visible: NSRect, intent: WindowActivation.Intent)?
    private let pendingTimeout = DemandTimer(owner: "web-card-first-size")
    /// The person's left mouse-down being dispatched now: when, and whether on the native control.
    private var personDown: (time: TimeInterval, onControl: Bool)?
    /// Each card's slot for its click-only control, in CSS px from the card's top left, as the page last laid it out.
    private var slots: [String: CGRect] = [:]
    /// Each card's click-only control, as the card last named it.
    private var controls: [String: PersonControl] = [:]
    /// The native click-only control, drawn over the shown card's slot.
    let personButton = ThemedBezelButton(frame: .zero)
    /// When the card last drew anew (a click begun sooner is not aimed at what shows now).
    private var armedAt: TimeInterval = 0
    /// When the native control last moved, changed or appeared.
    private(set) var controlPlacedAt: TimeInterval = 0

    /// - Parameters:
    ///   - descriptor: The card page's descriptor; its namespaces must include `cmux.card.` and each card's prefix.
    ///   - cards: The cards, each served at its own ``WebCard/prefix``.
    ///   - routes: Shared providers (such as `cmux.app.`).
    ///   - width: The width before the page reports its own.
    public init?(descriptor: PageDescriptor, cards: [any WebCard], routes: [PageRoute] = [], width: CGFloat = 460) {
        let host = WebCardHostProvider()
        let routes = routes + cards.map { PageRoute(prefix: $0.prefix, provider: $0) }
        guard let page = PageWebView(descriptor: descriptor, routes: routes + [PageRoute(prefix: WebCardHostProvider.prefix, provider: host)],
                                     options: Self.engineOptions) else { return nil }
        self.page = page
        self.host = host
        self.cards = Dictionary(cards.map { ($0.card, $0) }, uniquingKeysWith: { first, _ in first })
        // The page and, above it, the native click-only control, on the panel's glass.
        page.frame = surface.bounds
        page.autoresizingMask = [.width, .height]
        surface.addSubview(page)
        surface.addSubview(personButton)
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
        personButton.isHidden = true
        personButton.refusesFirstResponder = true
        personButton.target = self
        personButton.action = #selector(pressPerson(_:))
        personButton.setAccessibilityIdentifier("cmux.webCard.personControl")
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
            show(size: size, parent: window?.frame, visible: visible, intent: intent)
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
        armedAt = uptime
    }

    /// Names the card's click-only control (nil: none shows). The button draws over the slot the
    /// page leaves for it (`data-person-click`) while the card shows.
    public func setPersonControl(_ control: PersonControl?, card: String) {
        guard controls[card] != control else { return }
        controls[card] = control
        placePersonControl()
    }

    override public func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown else { return super.sendEvent(event) }
        let point = surface.convert(event.locationInWindow, from: nil)
        personDown = isPersonEvent(event) ? (event.timestamp, !personButton.isHidden && personButton.frame.contains(point)) : nil
        // The native control tracks its click inside this dispatch; a press after it is not this click.
        super.sendEvent(event)
        personDown = nil
    }

    /// SECURITY: the native control's click reaches the card only as the person's own left click on
    /// it (``countsPersonPress(down:onControl:upIsPerson:isKey:)``); a key, an Accessibility press, a
    /// posted event or a script never does.
    @objc private func pressPerson(_ sender: Any?) {
        guard let card, let down = personDown, let up = NSApp.currentEvent, up.type == .leftMouseUp,
              countsPersonPress(down: down.time, onControl: down.onControl, upIsPerson: isPersonEvent(up), isKey: isKeyWindow) else { return }
        personDown = nil
        cards[card]?.personPressed()
    }

    /// SECURITY: whether a press of the native control counts as the person's: a left click from the
    /// HID system that went down on the control, on the key panel, begun at least a double-click
    /// interval after the card last drew (a machine arrived and Confirm appeared under a pointer aimed
    /// at what was there before) and ``steadyControl`` after the control last moved, with the control enabled.
    func countsPersonPress(down: TimeInterval, onControl: Bool, upIsPerson: Bool, isKey: Bool) -> Bool {
        guard let card, controls[card]?.isEnabled == true, !personButton.isHidden else { return false }
        // The page moves the slot: a click right after the control moved is not aimed at it.
        return onControl && upIsPerson && isKey && down - armedAt >= NSEvent.doubleClickInterval
            && down - controlPlacedAt >= Self.steadyControl
    }

    /// Draws the shown card's control over its slot, at its own size (at least ``minimumControl``),
    /// centered on the slot and kept inside the card; hidden without a control or a slot.
    private func placePersonControl() {
        guard let card, let control = controls[card], let slot = slots[card], isVisible || pending != nil else {
            personButton.isHidden = true
            return
        }
        let zoom = max(page.webKitView.pageZoom * page.webKitView.magnification, 0.01)
        let bounds = surface.bounds
        if personButton.title != control.title { personButton.title = control.title }
        personButton.isEnabled = control.isEnabled
        let fitting = personButton.fittingSize
        let size = NSSize(width: min(max(fitting.width, Self.minimumControl.width), bounds.width),
                          height: min(max(fitting.height, Self.minimumControl.height), bounds.height))
        let center = CGPoint(x: slot.midX * zoom, y: bounds.height - slot.midY * zoom)
        let frame = NSRect(x: min(max(center.x - size.width / 2, bounds.minX), bounds.maxX - size.width),
                           y: min(max(center.y - size.height / 2, bounds.minY), bounds.maxY - size.height),
                           width: size.width, height: size.height).integral
        guard personButton.isHidden || personButton.frame != frame else { return }
        personButton.frame = frame
        personButton.isHidden = false
        controlPlacedAt = ProcessInfo.processInfo.systemUptime
    }

    /// The smallest the native control draws, whatever slot the page reports.
    static let minimumControl = NSSize(width: 72, height: 24)
    /// How long the native control stays put before a click on it counts (the page places it).
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
    func pageResized(card: String, width: CGFloat?, height: CGFloat, control target: CGRect?) {
        slots[card] = target
        let zoom = page.webKitView.pageZoom * page.webKitView.magnification
        let size = NSSize(width: ceil((width ?? frame.width / zoom) * zoom), height: ceil(height * zoom))
        guard size.height > 0 else { return }
        sizes[card] = size
        guard card == self.card else { return }
        if let pending, pending.card == card {
            show(size: size, parent: pending.parent, visible: pending.visible, intent: pending.intent)
        } else if isVisible {
            fit(size)
        }
        placePersonControl()
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
        rearm()
        placePersonControl()
    }

    /// Grows or shrinks downward, keeping the top edge where the person saw it.
    private func fit(_ size: NSSize) {
        guard abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func finish(_ card: String) {
        personButton.isHidden = true
        cards[card]?.closed()
    }
}

/// A card's click-only control (Confirm, Try Again): its title and whether it can be pressed. The
/// card names it; the panel draws it natively over the slot the page leaves for it.
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
            panel?.pageResized(card: card, width: width, height: CGFloat(height), control: Self.rect(params["guard"]))
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

    /// `{x, y, width, height}` in CSS px, nil when absent or malformed.
    static func rect(_ value: JSONValue?) -> CGRect? {
        guard let x = value?["x"]?.doubleValue, let y = value?["y"]?.doubleValue, let width = value?["width"]?.doubleValue,
              let height = value?["height"]?.doubleValue, [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Sends one command to the page; false when no page listens.
    @discardableResult
    func send(_ command: JSONValue) -> Bool {
        for listener in listeners.values { listener(command) }
        return !listeners.isEmpty
    }
}
