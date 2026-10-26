
/// The `create.tab` intervals of new tabs waiting for their first themed content frame (p09-observability task 030,
/// PL-cef-tab), keyed by the tab's id in its pane's strip. The app's content cache owns one.
///
/// A create path begins the interval in the key's turn (``begin(_:)``) and names its tab once the tab exists
/// (``expect(_:tab:standIn:)``): a stand-in shown in that turn also gets its instant. The pane that shows the tab
/// reports its content's frame signal (``presented(_:firstFrame:)``, ``FirstFrame``), and the interval ends at that content's first frame: a terminal's
/// first IOSurface, a page's first contentful paint, an agent or page tab's first paint, else the commit that shows
/// it. A tab that closes first ends with outcome closed (``released(_:)``, or the content closing). Each interval
/// ends exactly once.
///
/// The daemon's tab that replaces a stand-in shows the same content under its own id: a show of that content under
/// a new id moves the wait there, so a close of the daemon's tab still ends it.
@MainActor
public final class CreateTabTimings {
    /// How a shown tab's content reports its first frame.
    public struct FirstFrame {
        /// The content's identity: the same content shown under another tab id is the same wait.
        public let content: ObjectIdentifier
        /// Starts the wait; `done` runs once with how it ended. Returns what cancels the wait, if anything.
        public let wait: @MainActor (_ done: @escaping @MainActor (CreateTabInterval.Outcome) -> Void) -> (@MainActor () -> Void)?

        public init(content: ObjectIdentifier,
                    wait: @escaping @MainActor (_ done: @escaping @MainActor (CreateTabInterval.Outcome) -> Void) -> (@MainActor () -> Void)?) {
            self.content = content
            self.wait = wait
        }

        /// Content with no frame signal of its own: it shows at the commit after this turn (`boundary`).
        public static func atCommit(_ content: ObjectIdentifier, boundary: CommitBoundary = CommitBoundary()) -> Self {
            .init(content: content) { done in
                boundary.after { _ in done(.shown) }
                return nil
            }
        }
    }

    private struct Waiting {
        let interval: CreateTabInterval
        /// The content whose first frame it waits for, once shown.
        var content: ObjectIdentifier?
        var cancel: (@MainActor () -> Void)?
    }

    private var waiting: [String: Waiting] = [:]
    private let signposter: Signposter
    private let boundary: CommitBoundary

    /// - Parameters:
    ///   - signposter: The `create` signposter (tests pass one on their own trace runtime).
    ///   - boundary: The commit boundary content with no frame signal of its own ends at.
    public init(signposter: Signposter = .create, boundary: CommitBoundary = CommitBoundary()) {
        self.signposter = signposter
        self.boundary = boundary
    }

    /// The tabs waiting for their first frame.
    public var waitingTabs: Set<String> { Set(waiting.keys) }

    /// Begins a new tab's interval now: call it first in the key's turn.
    public func begin(_ kind: CreateTabInterval.Kind) -> CreateTabInterval {
        CreateTabInterval(kind: kind, signposter: signposter)
    }

    /// `interval`'s tab is `key`; `standIn`: it is a stand-in shown in this turn (its instant goes at this turn's
    /// commit). Call it before the pane shows the tab.
    public func expect(_ interval: CreateTabInterval, tab key: String, standIn: Bool) {
        guard interval.isOpen else { return }
        if let earlier = waiting.removeValue(forKey: key) { end(earlier, .closed) }
        waiting[key] = Waiting(interval: interval)
        if standIn { interval.standInShown(at: boundary) }
    }

    /// Whether any tab waits (a show checks this before it builds the content's frame signal).
    public var isWaiting: Bool { !waiting.isEmpty }

    /// Pane content of tab `key` is shown now; `firstFrame` is how it reports its first frame.
    public func presented(_ key: String, firstFrame: FirstFrame) {
        if waiting[key] == nil, let moved = waiting.first(where: { $0.value.content == firstFrame.content })?.key {
            waiting[key] = waiting.removeValue(forKey: moved) // the daemon's tab shows its stand-in's content
        }
        guard var entry = waiting[key], entry.content == nil else { return }
        entry.content = firstFrame.content
        waiting[key] = entry
        let interval = entry.interval
        let cancel = firstFrame.wait { [weak self] outcome in self?.finish(interval, outcome) }
        // The wait may have ended at once (a page that painted already).
        if interval.isOpen { waiting[key]?.cancel = cancel }
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

    private func finish(_ interval: CreateTabInterval, _ outcome: CreateTabInterval.Outcome) {
        if let key = waiting.first(where: { $0.value.interval === interval })?.key { waiting[key] = nil }
        interval.end(outcome)
    }

    private func end(_ entry: Waiting, _ outcome: CreateTabInterval.Outcome) {
        entry.cancel?()
        entry.interval.end(outcome)
    }
}
