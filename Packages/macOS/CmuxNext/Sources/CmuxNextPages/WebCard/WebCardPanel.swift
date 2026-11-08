public import AppKit
public import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import WebKit

/// A floating web card host (first user: the server cards, design/server-cards.md): a borderless,
/// non-activating glass panel near the top center of the cmux window, on every Space and over full
/// screen, that shows one warm first-party React page (any descriptor; `cmux.server-cards`), one card per route
/// (`#/pair-invite`, ...). The page and its providers are made once and kept: a later open swaps
/// the route, never loads a page.
///
/// The page drives its own size and close (`cmux.card.*`, ``WebCardHostProvider``):
/// - `cmux.card.resize {card, height, width?}` (CSS px): the page measured its content; the panel
///   grows or shrinks downward, keeping its top edge where the person saw it;
/// - `cmux.card.close {card}`: the card's Cancel or Done ran; the panel hides;
/// - stream `cmux.card.commands`: `{command: "cancel"}` when Escape reaches the panel outside the
///   page (the card runs its own Cancel).
///
/// A card plugs in as a ``WebCard``: a page provider for its own `cmux.<card>.` prefix that hears
/// its opening and closing. A card that takes an action only from the person's own click
/// (approve, allow) asks its ``WebCard/host`` ``isPersonClick(_:on:)``, which reads the click from the
/// panel's own events and the control under it from the panel's own hit test.
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
    /// The card the panel shows (its route without `#/`), nil before the first opening.
    public private(set) var card: String?
    /// Whether an event is the person's own input (the app's strict source check); with none set, none is.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool = { _ in false }
    /// Where a card shows, from its size, the parent window's frame and the screen's visible frame;
    /// by default ``placement(size:over:in:)`` (top center). The join consent ask sets the top right.
    public var place: @MainActor (CGSize, NSRect?, NSRect) -> NSRect = { WebCardPanel.placement(size: $0, over: $1, in: $2) }
    /// Orders in over every app without activating cmux or taking the keys (an ask that shows while
    /// another app is in front), in place of ``WindowActivation``'s plan.
    public var ordersFrontRegardless = false
    /// The last size each card's page reported, in points.
    private var sizes: [String: NSSize] = [:]
    /// An opening waiting for its card's first size: where and how it shows.
    private var pending: (card: String, parent: NSRect?, visible: NSRect, intent: WindowActivation.Intent)?
    private let pendingTimeout = DemandTimer(owner: "web-card-first-size")
    /// The person's last left click on the panel: its down and up event times, and the control each
    /// landed on (``controlAt``, asked as the event arrived).
    private var personClick: (down: TimeInterval, downOn: ControlProbe, up: TimeInterval?, upOn: ControlProbe?)?
    /// SECURITY: the `data-action` of the enabled control under a point of the page (CSS px,
    /// ``pagePoint(_:)``), or nil; it answers through `done`. The panel asks it for each mouse-down
    /// and mouse-up of the person's, before the page gets the event. By default a hit test in a
    /// content world of the panel's own, which the page's script cannot reach or patch (tests set a stand-in).
    public var controlAt: @MainActor (CGPoint, @escaping @MainActor (String?) -> Void) -> Void = { _, done in done(nil) }
    /// When the card last drew anew (a click begun sooner is not aimed at what shows now).
    private var armedAt: TimeInterval = 0
    /// Goes up whenever the card draws anew or closes: a click checked before a wait counts only
    /// when this is the same after it.
    private var generation = 0
    /// The click a person-only action already spent.
    private var spentClick: TimeInterval?

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
        glass = Glass.makePanel(content: page, style: .regular, cornerRadius: 14)
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
        // SECURITY: a card takes person-only actions, so no page probe (`debug.page`) or Web Inspector reaches it.
        page.refusesProbes = true
        controlAt = { [weak self] point, done in
            guard let self else { return done(nil) }
            self.hitTest(point, done: done)
        }
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    /// Shows `card` over `window` (the cmux window it belongs to; nil uses the screen's top).
    /// `takeKeys` is true when a person opened it by hand. A card the page has measured before
    /// shows at once at that size; a first opening shows when the page reports its size (or after
    /// ``firstSizeWait``), so the card never draws at a wrong height and then jumps.
    public func present(card: String, over window: NSWindow?, takeKeys: Bool) {
        let again = isVisible && self.card == card
        if let shown = self.card, shown != card, isVisible { finish(shown) }
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
        generation += 1
    }

    /// SECURITY: whether a page call comes from the person's own left click on one of `actions`
    /// (the controls' `data-action`): the call's gesture is a click the panel saw from the HID system
    /// (no key, script, Accessibility press or posted event), begun at least a double-click interval
    /// after the card last drew, not spent by an earlier call, and both its down and its up landed on
    /// an enabled control of `actions`, as the panel's own hit test read it when each event arrived.
    /// Nothing the page sends names the control: a genuine click on the Name field followed by a
    /// script's press of Confirm, whatever it claims, is refused.
    public func isPersonClick(_ context: PageCallContext, on actions: Set<String>) async -> Bool {
        guard context.userGesture, let gesture = context.gestureEvent, let click = personClick, let up = click.up,
              let upOn = click.upOn, gesture == up || gesture == click.down,
              click.down - armedAt >= NSEvent.doubleClickInterval, spentClick != up else { return false }
        spentClick = up
        let drawn = generation
        guard let downAction = await click.downOn.value, let upAction = await upOn.value else { return false }
        // The card drew anew or closed (both move the generation) while the hit test answered: the click was
        // aimed at what was there before.
        return generation == drawn && downAction == upAction && actions.contains(downAction)
    }

    /// A point of the panel's window in the page's CSS px, top-left origin (what
    /// `getBoundingClientRect()` measures in): the page is zoomed by the interface scale.
    public func pagePoint(_ windowPoint: NSPoint) -> CGPoint {
        let local = page.convert(windowPoint, from: nil)
        let zoom = page.webKitView.pageZoom * page.webKitView.magnification
        let y = page.isFlipped ? local.y : page.bounds.height - local.y
        return CGPoint(x: local.x / zoom, y: y / zoom)
    }

    /// The hit test's content world: the page's script runs in another, so it can neither see this
    /// script nor change the DOM methods it calls.
    private static let hitTestWorld = WKContentWorld.world(name: "cmux.webCard.hitTest")
    /// The enabled control (`[data-action]`) under `point`, read in ``hitTestWorld``. Sent before
    /// the event reaches the page, so it reads the card as the person saw it. Chromium has no such
    /// world here, so a card there takes no person-only action.
    private func hitTest(_ point: CGPoint, done: @escaping @MainActor (String?) -> Void) {
        guard page.chromiumSession == nil else { return done(nil) }
        let script = """
            const control = document.elementFromPoint(x, y)?.closest("[data-action]");
            return control && !control.matches(":disabled") ? control.getAttribute("data-action") : null;
            """
        // Called now, not from a Task: the script then reaches the page's process before the event does.
        page.webKitView.callAsyncJavaScript(script, arguments: ["x": Double(point.x), "y": Double(point.y)], in: nil,
                                            in: Self.hitTestWorld) { result in done((try? result.get()) as? String) }
    }

    override public func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            personClick = isPersonEvent(event) ? (event.timestamp, probe(event), nil, nil) : nil
        case .leftMouseUp:
            if let click = personClick, isPersonEvent(event) {
                personClick = (click.down, click.downOn, event.timestamp, probe(event))
            } else {
                personClick = nil
            }
        case .keyDown:
            personClick = nil
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Asks ``controlAt`` what `event` landed on, now, before the page gets it.
    private func probe(_ event: NSEvent) -> ControlProbe {
        let probe = ControlProbe()
        controlAt(pagePoint(event.locationInWindow)) { probe.resolve($0) }
        return probe
    }

    // MARK: - The page's requests

    /// Escape outside the page: the card runs its own Cancel; with no page listening, the panel hides.
    override public func cancelOperation(_ sender: Any?) {
        if !host.send(["command": "cancel"]) { orderOut(nil) }
    }

    /// Closing the card any other way closes its provider's session too.
    override public func orderOut(_ sender: Any?) {
        pending = nil
        pendingTimeout.cancel()
        generation += 1 // a click still being checked counts for nothing once the card is gone
        let shown = isVisible ? card : nil
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
            show(size: size, parent: pending.parent, visible: pending.visible, intent: pending.intent)
        } else if isVisible {
            fit(size)
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
        setFrame(place(size, parent, visible), display: false)
        if ordersFrontRegardless { orderFrontRegardless() } else { WindowActivation.show(self, intent) }
        if intent == .raise { page.focusPage() }
        rearm()
    }

    /// Grows or shrinks downward, keeping the top edge where the person saw it.
    private func fit(_ size: NSSize) {
        guard abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func finish(_ card: String) {
        personClick = nil
        generation += 1
        cards[card]?.closed()
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
    /// The panel that shows the card (the panel sets it): ``WebCardPanel/isPersonClick(_:on:)`` and ``WebCardPanel/rearm(at:)``.
    var host: WebCardPanel? { get set }
    /// The card opens; `again` when it already showed (a live session may stay).
    func opened(again: Bool)
    /// The card closed any way (Cancel, Done, Escape, another card, its owner): its session ends.
    func closed()
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

/// One hit test's answer, awaited by ``WebCardPanel/isPersonClick(_:on:)``: the first answer counts.
@MainActor
final class ControlProbe {
    private var answer: String??
    private var waiters: [CheckedContinuation<String?, Never>] = []

    func resolve(_ action: String?) {
        guard answer == nil else { return }
        answer = .some(action)
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: action) }
    }

    var value: String? {
        get async {
            if let answer { return answer }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }
}
