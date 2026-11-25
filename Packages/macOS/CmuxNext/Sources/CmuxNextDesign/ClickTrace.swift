public import AppKit
import CmuxNextWakeups

/// Where each of the person's clicks went, in every build (`cmux app clicks`, control method `input.clicks`).
///
/// Leo, 2026-11-22: "for some reason i cant click into the composer of the gui chat to focus on it rn". It passed on
/// its own two minutes later, and a release build had kept nothing that said where those clicks went (#49788). Now
/// each press records one line: the window AppKit gave it (its class and number: a page window, a divider catcher
/// panel, the overlay panel, the cmux window), whether the overlay panel took it from the window under it and where
/// a catcher or the overlay forwarded it, what each Chromium page did with the focus grant the click asked for
/// (granted, kept for a first-frame hold or a motion, skipped), and the key window and first responder once AppKit
/// dispatched it. No text, no title, no URL: class names, window numbers, rounded points and tab ids.
///
/// One per cmux window, owned by its ``WindowOverlayHost`` (`clickTrace`); `input.clicks` merges every window's.
/// Bounded: a ring of ``capacity`` presses; a page grant attaches to the newest press only within ``grantWindow``.
@MainActor
public final class ClickTrace {
    /// One press.
    public struct Entry: Codable, Equatable, Sendable {
        public var seq: UInt64
        /// Wall-clock time of the press, ISO 8601 with milliseconds.
        public var at: String
        /// `left`, `right` or `other`.
        public var button: String
        /// The press in screen points, rounded.
        public var x: Int
        public var y: Int
        /// The class of the window AppKit dispatched the press to (`CefNSWindow`, `DividerMousePanel`, ...).
        public var window: String
        public var windowNumber: Int
        /// The overlay panel took the press from the window under it (a toast, a dialog, an agent's cursor tag).
        public var overlayTook: Bool = false
        /// The window a catcher panel or the overlay forwarded the press to.
        public var forwardedTo: String?
        public var forwardedToNumber: Int?
        /// Each Chromium page focus grant the press led to: `tab: outcome`.
        public var pageGrants: [String] = []
        /// Once AppKit dispatched the press: the key window's class and number, and the first responder's class.
        public var keyWindow: String?
        public var keyWindowNumber: Int?
        public var firstResponder: String?

        enum CodingKeys: String, CodingKey {
            case seq, at, button, x, y, window
            case windowNumber = "window_number"
            case overlayTook = "overlay_took"
            case forwardedTo = "forwarded_to"
            case forwardedToNumber = "forwarded_to_number"
            case pageGrants = "page_grants"
            case keyWindow = "key_window"
            case keyWindowNumber = "key_window_number"
            case firstResponder = "first_responder"
        }
    }

    /// The control method `cmux app clicks` reads (`CLICKS_METHOD` in cmux-tui's cli/app.rs; a test holds the two equal).
    nonisolated public static let controlMethod = "input.clicks"

    /// What `input.clicks` answers: the newest presses, oldest first, and how many the ring holds.
    public struct Report: Codable, Equatable, Sendable {
        public var capacity: Int
        public var clicks: [Entry]
    }

    public func report(limit: Int?) -> Report {
        Self.report([self], limit: limit)
    }

    /// Several windows' presses as one list, oldest first (by time), the newest `limit` of them.
    public static func report(_ traces: [ClickTrace], limit: Int?) -> Report {
        let all = traces.flatMap { $0.entries() }.sorted { ($0.at, $0.seq) < ($1.at, $1.seq) }
        let clicks = limit.map { $0 >= 0 && $0 < all.count ? Array(all.suffix($0)) : all } ?? all
        return Report(capacity: Self.capacity, clicks: clicks)
    }

    public static let capacity = 200
    /// A grant this long after the newest press is that press's; a later one (a key, a switch) is no click's.
    public static let grantWindow: TimeInterval = 1.5
    static let grantsPerPress = 4

    private var ring: [Entry] = []
    private var head = 0
    private var nextSeq: UInt64 = 1
    /// The newest press's ring index and its uptime, while grants may still attach to it.
    private var open: (index: Int, uptime: TimeInterval, timestamp: TimeInterval)?
    private let clock: () -> TimeInterval
    private let now: () -> Date

    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, now: @escaping () -> Date = Date.init) {
        self.clock = clock
        self.now = now
    }

    private var monitor: Any?

    /// Records every press that reaches `window`, one of its child windows (a page, a divider catcher) or its overlay
    /// panel, from now on (its ``WindowOverlayHost`` starts it; idempotent). The monitor sees a press as it is
    /// dequeued, before any window or the overlay panel's own monitor handles it, and returns it unchanged; where the
    /// keyboard went is read after the next frame commit, after the press's dispatch and its focus changes.
    func startMonitoring(window: NSWindow, panel: NSWindow) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self, weak window, weak panel] event in
            guard let self, let window, let source = event.window,
                  source === window || source.parent === window || source === panel else { return event }
            self.press(event, window: source)
            let timestamp = event.timestamp
            AfterFrameCommit().run { [weak self] in self?.settled(timestamp: timestamp, keyWindow: NSApp.keyWindow) }
            return event
        }
    }

    /// The window closed: no more presses are recorded.
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    public static func isPress(_ type: NSEvent.EventType) -> Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }

    /// A press came (``startMonitoring(window:panel:)``), or the overlay took one before dispatch (``overlayTook(_:from:panel:)``).
    /// A second report of the same event (same timestamp) adds no line.
    public func press(_ event: NSEvent, window: NSWindow?) {
        guard Self.isPress(event.type) else { return }
        if let open, open.timestamp == event.timestamp, open.timestamp != 0 { return }
        let screen = window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        append(Entry(seq: 0, at: Self.stamp(now()), button: Self.button(event.type), x: Self.point(screen.x),
                     y: Self.point(screen.y), window: Self.name(window), windowNumber: window?.windowNumber ?? -1),
               timestamp: event.timestamp)
    }

    /// A press coordinate as a whole screen point, never a trap. `Int(_:)` traps on NaN, an infinity or a value past
    /// Int's range, and a posted or synthesized press can carry one: Nightly 4518008579501 and every Nightly after it
    /// died with SIGTRAP in `press` 3 s after its first window on each onboarding walk (cmuxterm-hq
    /// onboarding_golden_path_probe gone_why), when CuaDriver pressed Meet Chief's buttons. A point that is not a
    /// finite number records as 0; one past the range records as the nearest bound.
    nonisolated static func point(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        if rounded >= CGFloat(Int.max) { return Int.max }
        if rounded <= CGFloat(Int.min) { return Int.min }
        return Int(rounded)
    }

    /// The overlay panel took a press that the window server gave to `source` (`WindowOverlayHost.takeEventFromBelow`).
    public func overlayTook(_ event: NSEvent, from source: NSWindow?, panel: NSWindow) {
        guard Self.isPress(event.type) else { return }
        press(event, window: source)
        update { entry in
            entry.overlayTook = true
            entry.forwardedTo = Self.name(panel)
            entry.forwardedToNumber = panel.windowNumber
        }
    }

    /// A catcher panel or the overlay panel sent the newest press on to `target`.
    public func forwarded(_ event: NSEvent, to target: NSWindow) {
        guard Self.isPress(event.type), open?.timestamp == event.timestamp else { return }
        update { entry in
            entry.forwardedTo = Self.name(target)
            entry.forwardedToNumber = target.windowNumber
        }
    }

    /// A Chromium page's focus grant ran (`CEFTab.grantFocus`): `outcome` is `granted`, `skipped: has the keys`,
    /// `kept: first-frame hold` or `kept: motion`. It attaches to the newest press within ``grantWindow``.
    public func pageGrant(tab: String, outcome: String) {
        guard let open, clock() - open.uptime <= Self.grantWindow else { return }
        update { entry in
            if entry.pageGrants.count < Self.grantsPerPress { entry.pageGrants.append("\(tab): \(outcome)") }
        }
    }

    /// AppKit dispatched the press (the newest, else no line changes): where the keyboard is now.
    public func dispatched(_ event: NSEvent, keyWindow: NSWindow?) {
        guard Self.isPress(event.type) else { return }
        settled(timestamp: event.timestamp, keyWindow: keyWindow)
    }

    func settled(timestamp: TimeInterval, keyWindow: NSWindow?) {
        guard open?.timestamp == timestamp else { return }
        update { entry in
            entry.keyWindow = keyWindow.map { Self.name($0) }
            entry.keyWindowNumber = keyWindow?.windowNumber
            entry.firstResponder = keyWindow?.firstResponder.map { String(describing: type(of: $0)) }
        }
    }

    /// The newest `limit` presses (all when nil), oldest first.
    public func entries(limit: Int? = nil) -> [Entry] {
        let ordered = ring.count < Self.capacity ? ring : Array(ring[head...] + ring[..<head])
        guard let limit, limit >= 0, limit < ordered.count else { return ordered }
        return Array(ordered.suffix(limit))
    }

    // MARK: Ring

    private func append(_ entry: Entry, timestamp: TimeInterval) {
        var entry = entry
        entry.seq = nextSeq
        nextSeq += 1
        let index: Int
        if ring.count < Self.capacity {
            ring.append(entry)
            index = ring.count - 1
        } else {
            index = head
            ring[head] = entry
            head = (head + 1) % Self.capacity
        }
        open = (index, clock(), timestamp)
    }

    private func update(_ change: (inout Entry) -> Void) {
        guard let open, ring.indices.contains(open.index) else { return }
        change(&ring[open.index])
    }

    static func name(_ window: NSWindow?) -> String {
        window.map { String(describing: type(of: $0)) } ?? "none"
    }

    static func button(_ type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown: "left"
        case .rightMouseDown: "right"
        default: "other"
        }
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
