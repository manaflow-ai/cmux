public import AppKit
public import CmuxNextWakeups
import CmuxNextCompat
public import CmuxNextDesignTokens
public import CmuxNextInput
public import CmuxNextAppearance

/// The one owner of hover cards in the app (plans/cmux-next/hovercards.md).
///
/// It holds the pure `HoverCardMachine`, the one card window and the one
/// timer, and turns the world into the machine's events: pointer moves from
/// the sources, a fresh hit test of the pointer after any geometry change
/// (content can move under a still pointer, and tracking areas then send
/// nothing), dismissals, suppressions and removed targets. Nothing polls
/// while no card shows (a pointer resting on a card is the one exception,
/// below): the only timer is a one-shot `DemandTimer`, armed only in a pending,
/// leaving, grace or pinned phase; the input tap subscription for dismissals
/// exists only while a card is pending or shown.
///
/// Hover intent (`HoverIntentTiming`): a pointer moving from a shown card's
/// target toward the card (the safe triangle, `CGRect.isAimedAt`) does not hand the
/// card to a target it crosses, and a pointer resting on the card keeps it;
/// the card ignores the mouse, so each leave deadline looks where the
/// pointer is (one timer per grace, about five a second, while the pointer
/// rests on the card; any move, click, key or the app going inactive ends it).
@MainActor
public final class HoverCardCoordinator {
    public private(set) var machine = HoverCardMachine()
    private(set) var sources: [ObjectIdentifier: WeakSource] = [:]
    /// The source of each target the machine knows (the last hit, the active one).
    private var owners: [HoverTargetID: WeakSource] = [:]
    private let timer: DemandTimer
    var panel: HoverCardPanel?
    /// A card its owner shows in the one card window (`presentOwned`), nil while none does.
    var owned: HoverCardOwned?
    private var activated: HoverTargetID?
    /// The tap observer of key presses and clicks, which end a card: held only while a card is
    /// pending or shown. An observer, so an intercept that consumes the key (a modal's Escape)
    /// still ends the card.
    var dismissals: InputSubscription?
    /// The tap intercept for wheel scrolls (``InputEventTap/InterceptOrder/popup``): a scroll on the
    /// shown card is the card's and goes no further; any other ends the card. Held with ``dismissals``.
    var scrolls: InputSubscription?
    /// Pointer moves while a card shows: the card ignores the mouse, so over it no source
    /// sees the pointer leave it; this tap observer sees it at once (no wait for a deadline).
    var cardMoves: InputSubscription?
    /// Those moves on the card parent's frames (`pointerFrameHover`); nil: each move reaches the card now.
    var cardMoveFrames: PointerFrameConsumer?
    /// Card moves checked (debug and tests: at most 2 per frame interval with the parent's frames).
    var cardMoveChecks = 0
    /// The app's input tap (the App's composition root passes it; a strip's default coordinator,
    /// replaced before it shows a card, and tests that drive the machine directly have none).
    let inputTap: InputEventTap?
    /// The card's parent and whether it took mouse moves before the card showed: while a
    /// card shows, the parent takes them everywhere, so moves over the card reach `cardMoves`.
    var movesParent: (window: NSWindow, accepted: Bool)?
    /// The last pointer move was on the card.
    var pointerWasOnCard = false
    var observers: [MainActorObservation] = []
    /// The app's notice fan-outs (``init(clock:input:changes:appEvents:workspaceEvents:)``) and the subscriptions on them.
    let appEvents: AppEvents?
    let workspaceEvents: AppEvents?
    var appWatches: [EventSubscription] = []
    /// `sidebar.hoverCards.enabled` or calm mode changes (``AppearanceSignals/Signal/hoverCards``).
    var hoverCardsWatch: AppearanceSignals.Subscription?
    /// The last window-server answer to "which window is on top here", for its point and the time it was
    /// asked: valid for one display frame (``topWindowLifetime``), so a burst of relayouts under a still
    /// pointer asks once, and a window of another app or a non-key panel brought forward shows by the
    /// next frame (no notification of this app says so).
    var topWindowCache: (point: CGPoint, at: CFTimeInterval, number: Int)?
    /// One frame at 120 Hz: how long a cached top window holds.
    static let topWindowLifetime: CFTimeInterval = 1.0 / 120
    /// Machine events delivered (debug report).
    public private(set) var eventCount = 0
    /// Told each time the shown card changes (shown, hidden or moved to another target).
    let changes: OverlayChangeFeed?

    /// The real mouse in screen coordinates (tests inject one).
    public var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// The last pointer event's location and the real mouse at that time.
    private var eventPointer: (point: CGPoint, mouse: CGPoint)?
    /// The pointer at the last move, the safe triangle's apex for the next.
    private var lastPointer: CGPoint?
    /// The escape slot beside the row of the last `.besideRow` card, that row's target, and the
    /// row's frame and source when the slot was taken (`HoverCardEscapeGeometry`): the pointer in
    /// it gives that row no card, so moving into the slot dismisses the card and moving on inside
    /// it never brings the card back. Kept after the card hides until the pointer leaves the
    /// slot, or the row moves (a scroll).
    private var escape: (slot: CGRect, target: HoverTargetID, anchor: CGRect, source: WeakSource)?

    /// The pointer now: the last pointer event's location while the real
    /// mouse has not moved since (the same point for real events; the
    /// event's own point for synthesized ones, `debug.mouse`), else the
    /// real mouse (it moved where no source saw it).
    public func currentPointer() -> CGPoint {
        let mouse = pointerLocation()
        if let eventPointer, eventPointer.mouse == mouse { return eventPointer.point }
        return mouse
    }
    /// The clock the cached top window expires on, in seconds (tests inject one).
    public var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// The number of the topmost window under a screen point, ignoring
    /// the card itself (tests inject one).
    public var windowNumberAt: ((CGPoint) -> Int?)?
    /// This app's visible windows that take the mouse, front first: a
    /// no-activate run (a capture slot) hit-tests against these. Tests inject
    /// plain numbers and frames, so the window server's state cannot flake them.
    public var ownWindows: () -> [(number: Int, frame: CGRect)] = {
        (NSWindow.windowNumbers(options: []) ?? [])
            .compactMap { NSApp?.window(withWindowNumber: $0.intValue) }
            .filter { $0.isVisible && !$0.ignoresMouseEvents }
            .map { ($0.windowNumber, $0.frame) }
    }
    /// Cards show only while the app is active (always in a no-activate
    /// test run, which is never active); tests inject one.
    public var appIsActive: () -> Bool = { NSApp.isActive || WindowPlacement.noActivate }
    /// `sidebar.hoverCards.enabled` and not calm mode (`ui.calm`): off, the
    /// pointer gives no target a card (a row's, a tab's or a user's custom
    /// one); Show Resource Usage still pins one. Tests inject one.
    public var hoverCardsEnabled: () -> Bool = { DesignSettings.shared.showsHoverCards }
    /// A mouse button is down (a press, a drag, a selection): the pointer
    /// gives no target a card, as in Chrome. Tests inject one.
    public var mouseButtonDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    /// A coordinator whose dismissals listen on `input`, the app's one tap, and that tells `changes` when
    /// the shown card changes.
    ///
    /// - Parameters:
    ///   - clock: The clock the hover delays run on (tests pass a manual one).
    ///   - input: The app's input tap, which the dismissals listen on.
    ///   - changes: Told when the shown card changes.
    ///   - appEvents: The app's one fan-out of `NotificationCenter.default` notices: the app going inactive ends
    ///     the card. Nil (a strip's default coordinator, replaced before it shows a card; tests): no subscription.
    ///   - workspaceEvents: The app's one fan-out of the workspace center's notices: a Space change ends the card.
    public init(clock: any Clock<Duration> = ContinuousClock(), input: InputEventTap? = nil, changes: OverlayChangeFeed? = nil,
                appEvents: AppEvents? = nil, workspaceEvents: AppEvents? = nil) {
        // timer-class-allow: the person's dwell, grace and aim deadlines run on the injected clock the hover suites step; a MainDeadline wakes on uptime only
        timer = DemandTimer(owner: "HoverCards.delay", clock: clock)
        inputTap = input
        self.changes = changes
        (self.appEvents, self.workspaceEvents) = (appEvents, workspaceEvents)
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // The tap subscriptions stop when released.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { timer.cancel() }
    }

    // MARK: Sources

    public func register(_ source: any HoverCardSource) {
        installObserversIfNeeded()
        sources[ObjectIdentifier(source)] = WeakSource(source)
    }

    /// The source is going away: its active card ends.
    public func unregister(_ source: any HoverCardSource) {
        sources[ObjectIdentifier(source)] = nil
        let ids = owners.filter { $0.value.source === source || $0.value.source == nil }.map(\.key)
        for id in ids { targetRemoved(id) }
    }

    // MARK: Events

    /// The pointer moved over a source's window, to `point` (screen
    /// coordinates, from the event) when known.
    public func pointerMoved(to point: CGPoint? = nil) {
        if let point { eventPointer = (point, pointerLocation()) }
        let now = currentPointer()
        let timing = HoverIntentTiming.current
        machine.leaveWindow = timing.cardGrace
        machine.aimWindow = timing.cardAim
        let card = shownCardFrame
        let aiming = card?.isAimedAt(from: lastPointer, to: now) == true
        lastPointer = now
        // On the card the pointer is on no target (the card ignores the mouse,
        // so the window under it hit-tests): it holds the card.
        let onCard = card?.contains(now) == true
        pointerWasOnCard = onCard
        let escaped = escapeTarget(at: now)
        // A held mouse button (a press, a drag, a selection) gives no target a card, as in Chrome.
        let hit = onCard || mouseButtonDown() ? nil : hitTest(escaping: escaped)
        // On the card, or between a source's targets: a card that hides on leave waits (on the
        // card it stays while the pointer rests there; Lawrence 2026-10-19: the card touches its
        // tab, and moving onto it must not dismiss it). The escape slot beside a row bridges
        // nothing: the card goes on this move (Leo 2026-10-20). The gap between a row and its
        // card bridges only a pointer heading into the card: one going down past the row lets
        // the card go (Leo 2026-10-20).
        let inGap = card.map { panel?.escapeGeometry?.zone(at: now) == .gap || besideTarget(now, card: $0) } ?? false
        let bridging = hit == nil && !mouseButtonDown()
            && (onCard || (escaped == nil && (inGap ? aiming : bridges(at: now))))
        send(.hit(hit?.target, moved: true, aiming: aiming, bridging: bridging))
    }

    /// `point` is between the shown target's own frame and its card, beside the card (a sidebar
    /// row's card stands at the sidebar's edge, past the row's end): only a pointer heading
    /// into the card keeps it there.
    private func besideTarget(_ point: CGPoint, card: CGRect) -> Bool {
        guard let id = machine.shownTarget?.id,
              let target = owners[id]?.source?.hoverCardTargetFrame(for: id),
              point.y >= card.minY, point.y < card.maxY, !target.contains(point) else { return false }
        return card.minX >= target.maxX ? point.x >= target.maxX && point.x < card.minX
            : point.x < target.minX && point.x >= card.maxX
    }

    /// The shown card's frame on screen, nil while none shows.
    var shownCardFrame: CGRect? {
        guard machine.shownTarget != nil, let panel, panel.isShowingCard else { return nil }
        return panel.cardFrame
    }

    /// Whether the pointer rests on the shown card now.
    private func pointerIsOnCard() -> Bool { shownCardFrame?.contains(currentPointer()) == true }

    /// Content in `window` moved or changed (layout, strip or list scroll,
    /// column scroll, an animation frame, tabs added, removed or
    /// reordered). The pointer may now be over another target, or none,
    /// without having moved. Cheap when idle and the pointer is elsewhere.
    /// Nothing during a live resize: the pointer is on the window's edge,
    /// and every strip and list hit-tested again on every frame (resize
    /// jank, Leo on cosmic-gray 2026-10-13). Its end hit-tests once.
    public func geometryChanged(in window: NSWindow?) { geometryChanged(in: window, liveResizeEnded: false) }

    private func geometryChanged(in window: NSWindow?, liveResizeEnded: Bool) {
        // A full screen transition too: AppKit animates a snapshot, the pointer is not over what it shows.
        if !liveResizeEnded, Motion.isLiveResizing(window) { return }
        // Content moving under a held button (a click's relayout, a drag) changes nothing: a hit
        // of nil here would end the click's quiet, and the card would come back on release.
        if mouseButtonDown() { followShownTarget(); return }
        if machine.phase == .idle, machine.lastHit == nil {
            guard let window, window.frame.contains(currentPointer()) else { return }
        }
        let onCard = pointerIsOnCard()
        let hit = onCard ? nil : hitTest(escaping: escapeTarget(at: currentPointer()))
        // Content moving under a pointer resting on the card keeps the card.
        send(.hit(hit?.target, moved: false, bridging: onCard))
        // A pinned card whose target went away (closed while not hovered).
        if let active = machine.activeTarget, owners[active.id]?.source?.hoverCardAnchor(for: active.id) == nil {
            send(.targetRemoved(active.id))
        }
        followShownTarget()
    }

    public func dismiss(_ reason: HoverDismissal) {
        // The app or its Space going away closes an owner's card too (it takes clicks, so it
        // stays through key presses and clicks: its owner closes it then).
        if reason == .appDeactivated || reason == .windowResignedKey, let owned { endOwned(owned.id) }
        send(.dismiss(reason))
    }

    /// Hover cards were turned off: a pending or shown card goes now, a
    /// pinned one (Show Resource Usage) too, since the user just asked for no
    /// cards. Turned on: the next pointer move starts one.
    func hoverCardsSettingChanged() {
        guard !hoverCardsEnabled(), machine.activeTarget != nil else { return }
        dismiss(.action)
    }
    public func suppress(_ reason: HoverSuppression) { send(.suppress(reason)) }

    public func unsuppress(_ reason: HoverSuppression) {
        send(.unsuppress(reason))
        guard !mouseButtonDown() else { return }
        let onCard = pointerIsOnCard()
        send(.hit(onCard ? nil : hitTest(escaping: escapeTarget(at: currentPointer()))?.target, moved: false, bridging: onCard))
    }

    public func targetRemoved(_ id: HoverTargetID) {
        send(.targetRemoved(id))
        if machine.lastHit?.id != id, machine.activeTarget?.id != id { owners[id] = nil }
    }

    /// Shows `target`'s card now (Show Resource Usage), owned by `source`.
    public func pin(_ target: HoverTarget, from source: any HoverCardSource) {
        // An inactive app shows no card (its window would stay hidden).
        guard appIsActive() else { return }
        owners[target.id] = WeakSource(source)
        send(.pin(target))
    }

    /// `id`'s content changed: the shown card updates in place.
    public func contentChanged(_ id: HoverTargetID) {
        guard machine.shownTarget?.id == id, let body = owners[id]?.source?.hoverCardBody(for: id) else { return }
        body.applyTheme()
        panel?.refit(interactive: body.interactive)
    }

    /// The card shows `id` now.
    public func isShowing(_ id: HoverTargetID) -> Bool { machine.shownTarget?.id == id && panel?.isShowingCard == true }

    // MARK: Machine

    /// Feeds the machine. Events raised while effects run (a target that
    /// vanished before its card could show) queue behind the current one,
    /// so the reducer never re-enters.
    func send(_ event: HoverCardEvent) {
        queue.append(event)
        guard !draining else { return }
        draining = true
        let shown = machine.shownTarget
        while !queue.isEmpty {
            let next = queue.removeFirst()
            eventCount += 1
            let effects = machine.reduce(next)
            // Sources hear about activation before a body is built, so a
            // card that slides to another target shows that target's data.
            updateActivation()
            for effect in effects { run(effect) }
        }
        draining = false
        updateActivation()
        updateSubscriptions()
        pruneOwners()
        if machine.shownTarget != shown { changes?.signal() }
    }

    private var queue: [HoverCardEvent] = []
    private var draining = false

    private func run(_ effect: HoverCardEffect) {
        switch effect {
        case .schedule(let token, let delay):
            timer.scheduleOnMain(after: delay) { [weak self] in
                guard let self else { return }
                send(.pointerOnCard(pointerIsOnCard()))
                send(.deadline(token: token))
            }
        case .cancelTimer:
            timer.cancel()
        case .show(let target, let sliding):
            // A target takes the card from its owner's content: the owner hears it ended.
            finishOwned()
            guard let source = owners[target.id]?.source, let parent = source.hoverCardWindow, parent.isVisible,
                  let anchor = source.hoverCardAnchor(for: target.id), let body = source.hoverCardBody(for: target.id)
            else {
                // The target vanished between the hit test and the show.
                send(.targetRemoved(target.id))
                return
            }
            let panel = panel ?? HoverCardPanel()
            self.panel = panel
            panel.present(body: body.view, anchor: anchor, placement: body.placement, parent: parent,
                          themeAnchor: body.themeAnchor, sliding: sliding, interactive: body.interactive, applyTheme: body.applyTheme)
            // A hover card whose row's escape slot already holds the pointer (it rested in the
            // sidebar's margin beside the row) goes at once: the slot never shows its row's card.
            if case .shown(let shown) = machine.phase, shown.id == target.id, escapeTarget(at: currentPointer()) == target.id {
                send(.hit(nil, moved: false))
            }
        case .hide:
            // The machine's own card: an owner's card in the window stays.
            guard owned == nil else { return }
            panel?.dismiss()
        }
    }

    /// Tells sources when their card starts and stops being pending or shown.
    private func updateActivation() {
        let active = machine.activeTarget?.id
        guard active != activated else { return }
        if let old = activated { owners[old]?.source?.hoverCardDeactivated(old) }
        activated = active
        if let active { owners[active]?.source?.hoverCardActivated(active) }
    }

    private func pruneOwners() {
        let keep = Set([machine.lastHit?.id, machine.activeTarget?.id].compactMap(\.self))
        owners = owners.filter { keep.contains($0.key) }
    }

    // MARK: Geometry

    func windowGeometryChanged(_ number: Int?, liveResizeEnded: Bool) {
        guard let number, number != panel?.windowNumber,
              let window = sources.values.lazy.compactMap({ $0.source?.hoverCardWindow }).first(where: { $0.windowNumber == number })
        else { return }
        geometryChanged(in: window, liveResizeEnded: liveResizeEnded)
    }

    /// While shown, the card follows its target.
    private func followShownTarget() {
        guard let id = machine.shownTarget?.id, let anchor = owners[id]?.source?.hoverCardAnchor(for: id) else { return }
        panel?.follow(anchor)
    }

    /// The row whose escape slot holds `point`, if any. While a `.besideRow` card shows, the
    /// slot is that card's; after it hides, the last one lasts until the pointer leaves it.
    private func escapeTarget(at point: CGPoint) -> HoverTargetID? {
        if let shown = machine.shownTarget, let panel, panel.isShowingCard {
            escape = panel.escapeGeometry.flatMap { geometry in
                owners[shown.id].map { (slot: geometry.escapeSlot, target: shown.id, anchor: geometry.anchor, source: $0) }
            }
        }
        guard let escape else { return nil }
        guard escape.slot.contains(point), escape.source.source?.hoverCardAnchor(for: escape.target) == escape.anchor else {
            self.escape = nil
            return nil
        }
        return escape.target
    }

    /// The target under the pointer now, from the sources of the window on top at that point;
    /// never `escaping`, the row whose escape slot the pointer is in (the slot can lie in the
    /// sidebar's margin, where the row's own hit test still finds it).
    private func hitTest(escaping: HoverTargetID?) -> HoverCardHit? {
        guard let hit = hitTest(), hit.target.id != escaping else { return nil }
        return hit
    }

    /// The target under the pointer now, from the sources of the window
    /// on top at that point.
    private func hitTest() -> HoverCardHit? {
        guard appIsActive(), hoverCardsEnabled() else { return nil }
        let point = currentPointer()
        let top = topWindowNumber(at: point)
        for entry in sources.values {
            guard let source = entry.source, let window = source.hoverCardWindow, window.windowNumber == top,
                  let hit = source.hoverCardHit(at: point) else { continue }
            owners[hit.target.id] = entry
            return hit
        }
        return nil
    }

    // MARK: Verification

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1_000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// State for `debug.hover_cards`.
    public var report: [String: String] {
        [
            "phase": "\(machine.phase)",
            "last_hit": machine.lastHit?.id.rawValue ?? "-",
            "suppressions": machine.suppressions.map(\.rawValue).sorted().joined(separator: ","),
            "enabled": "\(hoverCardsEnabled())",
            "delay_ms": "\(Self.milliseconds(DesignSettings.shared.hoverCardDelay))",
            "pending_target": { if case .pending(let target, _) = machine.phase { target.id.rawValue } else { "-" } }(),
            "shown_target": machine.shownTarget?.id.rawValue ?? "-",
            "quiet": "\(machine.quiet)",
            "card_windows": "\(HoverCardPanel.liveInstances.load(ordering: .relaxed))",
            "card_showing": "\(panel?.isShowingCard == true)",
            "card_frame": panel.map { NSStringFromRect($0.cardFrame) } ?? "-",
            "anchor_frame": panel.map { NSStringFromRect($0.anchorFrame) } ?? "-",
            "timer_armed": "\(timer.isScheduled)",
            "dismissal_subscription": "\(dismissals != nil)",
            "sources": "\(sources.values.filter { $0.source != nil }.count)",
            "events": "\(eventCount)",
            "owned": owned?.id.rawValue ?? "-",
            "card_text": panel.map { $0.isShowingCard ? $0.bodyLines.joined(separator: "\n") : "" } ?? "",
        ]
    }
}

struct WeakSource {
    weak var source: (any HoverCardSource)?
    init(_ source: any HoverCardSource) { self.source = source }
}
