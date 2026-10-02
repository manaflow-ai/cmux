public import AppKit
import CmuxNextWakeups

/// The one owner of hover cards in the app (plans/cmux-next/hovercards.md).
///
/// It holds the pure `HoverCardMachine`, the one card window and the one
/// timer, and turns the world into the machine's events: pointer moves from
/// the sources, a fresh hit test of the pointer after any geometry change
/// (content can move under a still pointer, and tracking areas then send
/// nothing), dismissals, suppressions and removed targets. Nothing polls:
/// the only timer is a one-shot `DemandTimer`, armed only in a pending,
/// grace or pinned phase; the event monitor for dismissals exists only
/// while a card is pending or shown.
@MainActor
public final class HoverCardCoordinator {
    public private(set) var machine = HoverCardMachine()
    private var sources: [ObjectIdentifier: WeakSource] = [:]
    /// The source of each target the machine knows (the last hit, the active one).
    private var owners: [HoverTargetID: WeakSource] = [:]
    private let timer: DemandTimer
    private var panel: HoverCardPanel?
    private var activated: HoverTargetID?
    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []
    /// Machine events delivered (debug report).
    public private(set) var eventCount = 0

    /// The real mouse in screen coordinates (tests inject one).
    public var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// The last pointer event's location and the real mouse at that time.
    private var eventPointer: (point: CGPoint, mouse: CGPoint)?

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
    /// Cards show only while the app is active (always in a no-activate
    /// test run, which is never active); tests inject one.
    public var appIsActive: () -> Bool = { NSApp.isActive || WindowPlacement.noActivate }

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        timer = DemandTimer(owner: "HoverCards.delay", clock: clock)
    }

    /// App and window notifications, installed with the first source (a
    /// coordinator that never gets one, such as a strip's default before
    /// the App injects the shared one, costs nothing).
    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if !WindowPlacement.noActivate { self?.dismiss(.appDeactivated) } }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(.windowResignedKey) }
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let number = (note.object as? NSWindow)?.windowNumber
                MainActor.assumeIsolated { self?.windowGeometryChanged(number) }
            })
        }
    }

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        timer.cancel()
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
        send(.hit(hitTest()?.target, moved: true))
    }

    /// Content in `window` moved or changed (layout, strip or list scroll,
    /// column scroll, an animation frame, tabs added, removed or
    /// reordered). The pointer may now be over another target, or none,
    /// without having moved. Cheap when idle and the pointer is elsewhere.
    public func geometryChanged(in window: NSWindow?) {
        if machine.phase == .idle, machine.lastHit == nil {
            guard let window, window.frame.contains(currentPointer()) else { return }
        }
        let hit = hitTest()
        send(.hit(hit?.target, moved: false))
        // A pinned card whose target went away (closed while not hovered).
        if let active = machine.activeTarget, owners[active.id]?.source?.hoverCardAnchor(for: active.id) == nil {
            send(.targetRemoved(active.id))
        }
        followShownTarget()
    }

    public func dismiss(_ reason: HoverDismissal) { send(.dismiss(reason)) }
    public func suppress(_ reason: HoverSuppression) { send(.suppress(reason)) }

    public func unsuppress(_ reason: HoverSuppression) {
        send(.unsuppress(reason))
        send(.hit(hitTest()?.target, moved: false))
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
            timer.schedule(after: delay) { @MainActor [weak self] in self?.send(.deadline(token: token)) }
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
    }

    private func pruneOwners() {
        let keep = Set([machine.lastHit?.id, machine.activeTarget?.id].compactMap(\.self))
        owners = owners.filter { keep.contains($0.key) }
    }

    // MARK: Geometry

    private func windowGeometryChanged(_ number: Int?) {
        guard let number, number != panel?.windowNumber,
              let window = sources.values.lazy.compactMap({ $0.source?.hoverCardWindow }).first(where: { $0.windowNumber == number })
        else { return }
        geometryChanged(in: window)
    }

    /// While shown, the card follows its target.
    private func followShownTarget() {
        guard let id = machine.shownTarget?.id, let anchor = owners[id]?.source?.hoverCardAnchor(for: id) else { return }
        panel?.follow(anchor)
    }

    /// The target under the pointer now, from the sources of the window
    /// on top at that point.
    private func hitTest() -> HoverCardHit? {
        guard appIsActive() else { return nil }
        let point = currentPointer()
        let top = windowNumberAt?(point) ?? Self.topWindowNumber(at: point, excluding: panel?.windowNumber)
        for entry in sources.values {
            guard let source = entry.source, let window = source.hoverCardWindow, window.windowNumber == top,
                  let hit = source.hoverCardHit(at: point) else { continue }
            owners[hit.target.id] = entry
            return hit
        }
        return nil
    }

    private static func topWindowNumber(at point: CGPoint, excluding card: Int?) -> Int {
        let top = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard let card, top == card else { return top }
        return NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: card)
    }

    // MARK: Verification

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
            "quiet": "\(machine.quiet)",
            "card_windows": "\(HoverCardPanel.liveInstances)",
            "card_showing": "\(panel?.isShowingCard == true)",
            "card_frame": panel.map { NSStringFromRect($0.frame) } ?? "-",
            "timer_armed": "\(timer.isScheduled)",
            "monitor": "\(monitor != nil)",
            "sources": "\(sources.values.filter { $0.source != nil }.count)",
            "events": "\(eventCount)",
        ]
    }
}

private struct WeakSource {
    weak var source: (any HoverCardSource)?
    init(_ source: any HoverCardSource) { self.source = source }
}
