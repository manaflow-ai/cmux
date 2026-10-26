
/// The `create.tab` intervals of new tabs waiting for their first themed content frame (p09-observability task 030,
/// PL-cef-tab), keyed by the tab's id in its pane's strip. The app's content cache owns one.
///
/// A create path begins the interval in the key's turn (``begin(_:)``) and names its tab once the tab exists
/// (``expect(_:tab:standIn:)``), or names the daemon's surface the store has not listed yet
/// (``expect(_:surface:)``, bound to the tab when the pane lists it: ``listed(surface:tab:)``). A stand-in shown in
/// that turn also gets its instant. The pane that shows the tab reports its content's frame signal
/// (``presented(_:firstFrame:)``, ``FirstFrame``), and the interval ends at that content's first frame: a terminal's
/// first IOSurface, a page's first contentful paint, an agent or page tab's first paint. Content whose frame exists
/// already, or that has no signal of its own, ends at the Core Animation commit that shows it, as Chrome ends at the
/// presented frame. Each interval ends exactly once:
///
/// - shown: that frame (only this outcome is a create latency);
/// - closed: the tab closed first (``released(_:)``, the content closing, or its view going away);
/// - hidden: the tab stopped showing first (``hidden(_:)``, Chrome's `ContentToVisibleTimeReporter::TabWasHidden`);
///   the content's wait is cancelled, so nothing keeps reading a hidden tab's frames;
/// - missed: the commit boundary that would show the frame fired only after the run loop slept.
///
/// The daemon's tab that replaces a stand-in shows the same content under its own id: a show of that content under
/// a new id moves the wait there, so a close of the daemon's tab still ends it.
@MainActor
public final class CreateTabTimings {
    /// Runs `body` once after the Core Animation commit that ends this main run-loop turn, with how it fired.
    public typealias AfterCommit = @MainActor (_ body: @escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void

    /// How a shown tab's content reports its first frame.
    public struct FirstFrame {
        /// The content's identity (held weakly while it waits): the same content shown under another tab id is the
        /// same wait, and content that went away closed its tab.
        public let content: AnyObject
        /// Starts the wait; `done` runs once with how it ended (shown in the call itself: the frame exists already,
        /// and the interval ends at this turn's commit). Returns what cancels the wait, if anything.
        public let wait: @MainActor (_ done: @escaping @MainActor (CreateTabInterval.Outcome) -> Void) -> (@MainActor () -> Void)?

        public init(content: AnyObject,
                    wait: @escaping @MainActor (_ done: @escaping @MainActor (CreateTabInterval.Outcome) -> Void) -> (@MainActor () -> Void)?) {
            self.content = content
            self.wait = wait
        }

        /// Content with no frame signal of its own: it shows at the commit that shows it.
        public static func atCommit(_ content: AnyObject) -> Self {
            .init(content: content) { done in
                done(.shown)
                return nil
            }
        }
    }

    private struct Waiting {
        let interval: CreateTabInterval
        /// The content whose first frame it waits for, once shown.
        weak var content: AnyObject?
        var isPresented = false
        /// The content's wait is starting: a shown reported now means the frame exists already.
        var isStarting = false
        var cancel: (@MainActor () -> Void)?
    }

    private var waiting: [String: Waiting] = [:]
    /// Waits for a daemon surface the store has not listed as a tab yet.
    private var bySurface: [UInt64: CreateTabInterval] = [:]
    private let signposter: Signposter
    private let afterCommit: AfterCommit

    /// - Parameters:
    ///   - signposter: The `create` signposter (tests pass one on their own trace runtime).
    ///   - afterCommit: The commit boundary that shows content whose frame exists already (tests fire their own;
    ///     nil: the main run loop's ``CommitBoundary``).
    public init(signposter: Signposter = .create, afterCommit: AfterCommit? = nil) {
        self.signposter = signposter
        self.afterCommit = afterCommit ?? { CommitBoundary().after($0) }
    }

    /// The tabs waiting for their first frame.
    public var waitingTabs: Set<String> { Set(waiting.keys) }

    /// The open interval of tab `key`, while it waits for its first frame.
    public func interval(ofTab key: String) -> CreateTabInterval? { waiting[key]?.interval }

    /// The daemon surfaces waiting to be listed as a tab.
    public var waitingSurfaces: Set<UInt64> { Set(bySurface.keys) }

    /// Begins a new tab's interval now: call it first in the key's turn.
    public func begin(_ kind: CreateTabInterval.Kind) -> CreateTabInterval {
        CreateTabInterval(kind: kind, signposter: signposter)
    }

    /// Begins a new tab's interval now when the tab will show (`shows`: a foreground create in a window that draws
    /// it); nil otherwise: a tab no one sees is no create latency.
    public func begin(_ kind: CreateTabInterval.Kind, shows: Bool) -> CreateTabInterval? {
        shows ? begin(kind) : nil
    }

    /// `interval`'s tab is `key`; `standIn`: it is a stand-in shown in this turn (its instant goes at this turn's
    /// commit). Call it before the pane shows the tab.
    public func expect(_ interval: CreateTabInterval, tab key: String, standIn: Bool) {
        guard interval.isOpen else { return }
        if let earlier = waiting.removeValue(forKey: key) { end(earlier, .closed) }
        waiting[key] = Waiting(interval: interval)
        if standIn { interval.standInShown(afterCommit: afterCommit) }
    }

    /// `interval`'s tab is the one the daemon made on `surface`, which the store may not list yet (the reply came
    /// before its `tab-added` event): the wait is the tab's once the pane lists it (``listed(surface:tab:)``).
    public func expect(_ interval: CreateTabInterval, surface: UInt64) {
        guard interval.isOpen else { return }
        bySurface.updateValue(interval, forKey: surface)?.end(.closed)
    }

    /// The pane lists `surface`'s tab as `key`: a wait for that surface is the tab's now. Returns that wait's
    /// interval (nil: none waited for the surface), whose new terminal marks its `tab_added` stage here.
    @discardableResult
    public func listed(surface: UInt64, tab key: String) -> CreateTabInterval? {
        guard let interval = bySurface.removeValue(forKey: surface) else { return nil }
        expect(interval, tab: key, standIn: false)
        return interval
    }

    /// The pane will not show `surface`'s tab (its selection went to another new tab first): no sample.
    public func dropped(surface: UInt64) {
        bySurface.removeValue(forKey: surface)?.end(.hidden)
    }

    /// Whether any tab waits (a show checks this before it builds the content's frame signal).
    public var isWaiting: Bool { !waiting.isEmpty }

    /// The open `kind` interval that tab `key`, or the daemon's `surface` not listed yet, waits on; nil when neither
    /// waits (a restored, reattached or remade tab, or a create no one sees). A new terminal's stages are keyed by
    /// it (`NewTerminalTrace`).
    public func waitingInterval(_ kind: CreateTabInterval.Kind, tab key: String, surface: UInt64) -> CreateTabInterval? {
        guard let interval = waiting[key]?.interval ?? bySurface[surface], interval.isOpen, interval.kind == kind else { return nil }
        return interval
    }

    /// Pane content of tab `key` is shown now; `firstFrame` is how it reports its first frame.
    public func presented(_ key: String, firstFrame: FirstFrame) {
        closeRetired()
        if waiting[key] == nil, let moved = waiting.first(where: { $0.value.content === firstFrame.content })?.key {
            waiting[key] = waiting.removeValue(forKey: moved) // the daemon's tab shows its stand-in's content
        }
        guard var entry = waiting[key], !entry.isPresented else { return }
        entry.isPresented = true
        entry.content = firstFrame.content
        entry.isStarting = true
        waiting[key] = entry
        let interval = entry.interval
        let cancel = firstFrame.wait { [weak self] outcome in self?.finish(interval, outcome) }
        guard interval.isOpen, let current = waitingKey(of: interval) else { return } // it closed at once
        waiting[current]?.isStarting = false
        waiting[current]?.cancel = cancel
    }

    /// A pane switched from showing tab `previous` to tab `key` (`firstFrame`: its content's, nil when it shows
    /// none): `key` is presented, then `previous` is hidden. The order keeps a stand-in's wait whose content the
    /// daemon's tab shows now (``presented(_:firstFrame:)`` moved it).
    public func switched(from previous: String?, to key: String?, firstFrame: FirstFrame?) {
        if let key, let firstFrame { presented(key, firstFrame: firstFrame) }
        if let previous, previous != key { hidden(previous) }
    }

    /// The daemon's tab `real` took stand-in `key`'s place: the wait follows it.
    public func rekey(_ key: String, to real: String) {
        guard key != real, let entry = waiting.removeValue(forKey: key) else { return }
        if let earlier = waiting.updateValue(entry, forKey: real) { end(earlier, .closed) }
    }

    /// Tab `key` closed: its interval ends as closed when it is still waiting.
    public func released(_ key: String) {
        guard let entry = waiting.removeValue(forKey: key) else { return }
        end(entry, .closed)
    }

    /// Tab `key` stopped showing (another tab took its pane, its workspace stopped drawing): a wait still open
    /// ends with no sample and its content stops waiting.
    public func hidden(_ key: String) {
        guard let entry = waiting.removeValue(forKey: key) else { return }
        end(entry, .hidden)
    }

    private func waitingKey(of interval: CreateTabInterval) -> String? {
        waiting.first(where: { $0.value.interval === interval })?.key
    }

    private func finish(_ interval: CreateTabInterval, _ outcome: CreateTabInterval.Outcome) {
        guard let key = waitingKey(of: interval) else { return interval.end(outcome) }
        if outcome == .shown, waiting[key]?.isStarting == true {
            // The frame exists already: it reaches the screen with the commit that shows the content.
            waiting[key]?.isStarting = false
            afterCommit { [weak self] commit in self?.committed(interval, commit) }
            return
        }
        waiting[key] = nil
        interval.end(outcome)
    }

    private func committed(_ interval: CreateTabInterval, _ commit: CommitBoundary.Outcome) {
        guard interval.isOpen else { return } // closed or hidden before the commit
        if let key = waitingKey(of: interval) { waiting[key] = nil }
        interval.end(commit == .committed ? .shown : .missed)
    }

    /// Shown content that went away (its view retired with no close of its tab reported here) closed its tab.
    private func closeRetired() {
        let retired = waiting.filter { $0.value.isPresented && $0.value.content == nil }
        for (key, entry) in retired {
            waiting[key] = nil
            end(entry, .closed)
        }
    }

    private func end(_ entry: Waiting, _ outcome: CreateTabInterval.Outcome) {
        entry.cancel?()
        entry.interval.end(outcome)
    }
}
