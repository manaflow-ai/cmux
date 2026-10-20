public import AppKit
import CmuxNextWakeups

/// The one owner of hover cards in the app (plans/cmux-next/hovercards.md).
///
/// It holds the pure `HoverCardMachine`, the one card window and the one
/// timer, and turns the world into the machine's events: pointer moves from
/// the sources, a fresh hit test of the pointer after any geometry change
/// (content can move under a still pointer, and tracking areas then send
/// nothing), dismissals, suppressions and removed targets. Nothing polls
/// while no card shows (a pointer resting on a card is the one exception,
/// below): the only timer is a one-shot `DemandTimer`, armed only in a pending,
/// leaving, grace or pinned phase; the event monitor for dismissals exists only
/// while a card is pending or shown.
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
    private(set) var panel: HoverCardPanel?
    private var activated: HoverTargetID?
    private var monitor: Any?
    /// Pointer moves while a card shows: the card ignores the mouse, so over it no source
    /// sees the pointer leave it; this sees it at once (no wait for a deadline).
    private var moveMonitor: Any?
    /// The card's parent and whether it took mouse moves before the card showed: while a
    /// card shows, the parent takes them everywhere, so moves over the card reach `moveMonitor`.
    private var movesParent: (window: NSWindow, accepted: Bool)?
    /// The last pointer move was on the card.
    private var pointerWasOnCard = false
    private var observers: [any NSObjectProtocol] = []
    /// Machine events delivered (debug report).
    public private(set) var eventCount = 0

    /// The real mouse in screen coordinates (tests inject one).
    public var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// The last pointer event's location and the real mouse at that time.
    private var eventPointer: (point: CGPoint, mouse: CGPoint)?
    /// The pointer at the last move, the safe triangle's apex for the next.
    private var lastPointer: CGPoint?

    /// The pointer now: the last pointer event's location while the real
    /// mouse has not moved since (the same point for real events; the
    /// event's own point for synthesized ones, `debug.mouse`), else the
    /// real mouse (it moved where no source saw it).
    public func currentPointer() -> CGPoint {
        let mouse = pointerLocation()
        if let eventPointer, eventPointer.mouse == mouse { return eventPointer.point }
        return mouse
    }
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
    /// `sidebar.hoverCards.enabled`: off, the pointer gives no target a card
    /// (a row's, a tab's or a user's custom one); Show Resource Usage still
    /// pins one. Tests inject one.
    public var hoverCardsEnabled: () -> Bool = { DesignSettings.shared.hoverCardsEnabled }
    /// A mouse button is down (a press, a drag, a selection): the pointer
    /// gives no target a card, as in Chrome. Tests inject one.
    public var mouseButtonDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        timer = DemandTimer(owner: "HoverCards.delay", clock: clock)
    }

    /// App and window notifications, installed with the first source (a
    /// coordinator that never gets one, such as a strip's default before
    /// the App injects the shared one, costs nothing).
    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: DesignSettings.hoverCardsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoverCardsSettingChanged() } // main-proof: observer on queue: .main
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if !WindowPlacement.noActivate { self?.dismiss(.appDeactivated) } } // main-proof: observer on queue: .main
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(.windowResignedKey) } // main-proof: observer on queue: .main
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            let ended = name == NSWindow.didEndLiveResizeNotification
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let number = (note.object as? NSWindow)?.windowNumber
                MainActor.assumeIsolated { self?.windowGeometryChanged(number, liveResizeEnded: ended) } // main-proof: observer on queue: .main
            })
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            if let monitor { NSEvent.removeMonitor(monitor) }
            timer.cancel()
        }
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
        // A held mouse button (a press, a drag, a selection) gives no target a card, as in Chrome.
        let hit = onCard || mouseButtonDown() ? nil : hitTest()
        // On the card, or between a source's targets: a card that hides on leave waits (on the
        // card it stays while the pointer rests there; Lawrence 2026-10-19: the card touches its
        // tab, and moving onto it must not dismiss it).
        let bridging = hit == nil && !mouseButtonDown() && (onCard || bridges(at: now))
        send(.hit(hit?.target, moved: true, aiming: aiming, bridging: bridging))
    }

    /// The shown card's frame on screen, nil while none shows.
    private var shownCardFrame: CGRect? {
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
        if !liveResizeEnded, window?.inLiveResize == true { return }
        // Content moving under a held button (a click's relayout, a drag) changes nothing: a hit
        // of nil here would end the click's quiet, and the card would come back on release.
        if mouseButtonDown() { followShownTarget(); return }
        if machine.phase == .idle, machine.lastHit == nil {
            guard let window, window.frame.contains(currentPointer()) else { return }
        }
        let onCard = pointerIsOnCard()
        let hit = onCard ? nil : hitTest()
        // Content moving under a pointer resting on the card keeps the card.
        send(.hit(hit?.target, moved: false, bridging: onCard))
        // A pinned card whose target went away (closed while not hovered).
        if let active = machine.activeTarget, owners[active.id]?.source?.hoverCardAnchor(for: active.id) == nil {
            send(.targetRemoved(active.id))
        }
        followShownTarget()
    }

    public func dismiss(_ reason: HoverDismissal) { send(.dismiss(reason)) }

    /// Hover cards were turned off: a pending or shown card goes now, a
    /// pinned one (Show Resource Usage) too, since the user just asked for no
    /// cards. Turned on: the next pointer move starts one.
    private func hoverCardsSettingChanged() {
        guard !hoverCardsEnabled(), machine.activeTarget != nil else { return }
        dismiss(.action)
    }
    public func suppress(_ reason: HoverSuppression) { send(.suppress(reason)) }

    public func unsuppress(_ reason: HoverSuppression) {
        send(.unsuppress(reason))
        guard !mouseButtonDown() else { return }
        let onCard = pointerIsOnCard()
        send(.hit(onCard ? nil : hitTest()?.target, moved: false, bridging: onCard))
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
        panel?.refit()
    }

    /// The card shows `id` now.
    public func isShowing(_ id: HoverTargetID) -> Bool { machine.shownTarget?.id == id && panel?.isShowingCard == true }

    // MARK: Machine

    /// Feeds the machine. Events raised while effects run (a target that
    /// vanished before its card could show) queue behind the current one,
    /// so the reducer never re-enters.
    private func send(_ event: HoverCardEvent) {
        queue.append(event)
        guard !draining else { return }
        draining = true
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
        updateMonitor()
        pruneOwners()
    }

    private var queue: [HoverCardEvent] = []
    private var draining = false

    private func run(_ effect: HoverCardEffect) {
        switch effect {
        case .schedule(let token, let delay):
            timer.schedule(after: delay) { @MainActor [weak self] in
                guard let self else { return }
                send(.pointerOnCard(pointerIsOnCard()))
                send(.deadline(token: token))
            }
        case .cancelTimer:
            timer.cancel()
        case .show(let target, let sliding):
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
                          themeAnchor: body.themeAnchor, sliding: sliding, applyTheme: body.applyTheme)
        case .hide:
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

    /// Key presses, clicks and wheel scrolls end a card; the monitor exists
    /// only while one is pending or shown.
    private func updateMonitor() {
        let needed = machine.activeTarget != nil
        if needed, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                let reason: HoverDismissal = switch event.type {
                case .keyDown: .keyDown
                case .scrollWheel: .scrollWheel
                default: .click
                }
                self?.dismiss(reason)
                return event
            }
        } else if !needed, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        updateMoveMonitor()
    }

    /// While a card shows, pointer moves on it or just off it reach the machine: leaving the
    /// card hides it on that move (Lawrence 2026-10-19), not at the next deadline.
    private func updateMoveMonitor() {
        let parent = machine.shownTarget == nil ? nil : panel?.parent
        if movesParent?.window !== parent {
            if let old = movesParent { old.window.acceptsMouseMovedEvents = old.accepted }
            movesParent = parent.map { ($0, $0.acceptsMouseMovedEvents) }
            parent?.acceptsMouseMovedEvents = true
        }
        if parent != nil, moveMonitor == nil {
            moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                self?.cardPointerMoved(event.window.map { $0.convertPoint(toScreen: event.locationInWindow) })
                return event
            }
        } else if parent == nil, let moveMonitor {
            NSEvent.removeMonitor(moveMonitor)
            self.moveMonitor = nil
            pointerWasOnCard = false
        }
    }

    /// A pointer move seen by `moveMonitor`: only one on the card, or the first off it, is news
    /// (a source reports moves over its own targets itself).
    func cardPointerMoved(_ eventPoint: CGPoint?) {
        let point = eventPoint ?? pointerLocation()
        guard pointerWasOnCard || shownCardFrame?.contains(point) == true else { return }
        pointerMoved(to: point)
    }

    private func pruneOwners() {
        let keep = Set([machine.lastHit?.id, machine.activeTarget?.id].compactMap(\.self))
        owners = owners.filter { keep.contains($0.key) }
    }

    // MARK: Geometry

    private func windowGeometryChanged(_ number: Int?, liveResizeEnded: Bool) {
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

    /// The single-card invariant, checked live in debug builds
    /// (`debug.desync`): at most one card window exists and shows, and it
    /// shows what the machine says.
    public func singleCardViolations() -> [String] {
        var bad: [String] = []
        if HoverCardPanel.liveInstances > 1 { bad.append("\(HoverCardPanel.liveInstances) hover card windows exist") }
        let showing = panel?.isShowingCard == true
        if showing, machine.shownTarget == nil { bad.append("a card shows while the machine has none") }
        if !showing, let shown = machine.shownTarget, panel?.isVisible != true { bad.append("the machine shows \(shown.id) but no card is on screen") }
        return bad
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
            "card_windows": "\(HoverCardPanel.liveInstances)",
            "card_showing": "\(panel?.isShowingCard == true)",
            "card_frame": panel.map { NSStringFromRect($0.cardFrame) } ?? "-",
            "timer_armed": "\(timer.isScheduled)",
            "monitor": "\(monitor != nil)",
            "sources": "\(sources.values.filter { $0.source != nil }.count)",
            "events": "\(eventCount)",
            "card_text": panel.map { $0.isShowingCard ? $0.bodyLines.joined(separator: "\n") : "" } ?? "",
        ]
    }
}

struct WeakSource {
    weak var source: (any HoverCardSource)?
    init(_ source: any HoverCardSource) { self.source = source }
}
