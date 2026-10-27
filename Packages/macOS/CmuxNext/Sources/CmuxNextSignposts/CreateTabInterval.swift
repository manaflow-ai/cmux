import CmuxNextTrace
import os

/// One new tab's ``SignpostName/createTab`` interval, in every build (p09-observability task 030, PL-cef-tab):
/// begun in the turn of the person's key (or click), ended once at the tab's first themed content frame, or
/// when the tab closes or hides before that frame.
///
/// - The `os_signpost` interval carries `kind=<terminal|chromium|webkit|chat|page>` at its begin and
///   `outcome=<shown|closed|hidden|missed>` at its end; only a shown one is mirrored to MetricKit (a tab that
///   closed or hid first never drew for the person, and a missed commit holds idle time, so neither is a
///   create latency).
/// - The ring's async pair is keyed by the intent id (``intentID``): begin `arg0` the kind's code, end `arg0`
///   the outcome (``Outcome``). An instant of the same name and id (``standInShown(afterCommit:)``) marks the
///   commit of the stand-in, the tab the app shows before the daemon made it. The open's later steps (a chat's
///   stages) are instants on its ``scope``, keyed by the same id.
///
/// Chrome times the same span as one async trace event from the input to the presented frame of the new
/// content, closed by `ContentToVisibleTimeReporter` (content/browser/renderer_host/visible_time_request_trigger.h);
/// a tab hidden or closed before it presents ends its request without a sample
/// (`ContentToVisibleTimeReporter::TabWasHidden`).
///
/// ```swift
/// let create = CreateTabInterval(kind: .terminal)
/// create.standInShown()
/// session.whenFirstFrame { create.end(.shown) }
/// ```
@MainActor
public final class CreateTabInterval {
    /// What the new tab shows: the catalog's `kind` field.
    public nonisolated enum Kind: UInt8, CaseIterable, Sendable {
        case terminal, chromium, webkit, chat, page

        /// The name in the begin message.
        public var name: String {
            switch self {
            case .terminal: "terminal"
            case .chromium: "chromium"
            case .webkit: "webkit"
            case .chat: "chat"
            case .page: "page"
            }
        }

        /// The kind's number in the ring's begin `arg0` and the stand-in instant's `arg0`: its position + 1, so
        /// 0 stays "not given". Fixed: rings written by an older build decode with the same numbers.
        public var traceCode: UInt64 { UInt64(rawValue) + 1 }
    }

    /// How the interval ended: the ring's end `arg0`.
    public nonisolated enum Outcome: UInt64, Sendable {
        /// The tab's first themed content frame.
        case shown = 0
        /// The tab closed before its first frame.
        case closed = 1
        /// The tab stopped showing before its first frame (another tab or workspace took its place): no sample,
        /// as Chrome's `ContentToVisibleTimeReporter::TabWasHidden`.
        case hidden = 2
        /// The first frame was there, but the commit boundary that shows it fired only after the run loop slept
        /// (``CommitBoundary/Outcome/missed``): the time holds idle time, so no sample.
        case missed = 3

        var name: String {
            switch self {
            case .shown: "shown"
            case .closed: "closed"
            case .hidden: "hidden"
            case .missed: "missed"
            }
        }
    }

    /// What the tab shows.
    public let kind: Kind
    /// The intent's id: the ring pair's async id and the stand-in instant's `arg1`.
    public let intentID: UInt64
    /// How it ended; nil while open.
    public private(set) var outcome: Outcome?
    /// Whether the stand-in commit was marked.
    public private(set) var standInMarked = false

    private let signposter: Signposter
    private let signpostID: OSSignpostID
    private var interval: SignpostInterval?
    /// Whether the begin wrote a ring record: the open's instants go to the ring only then, as its end does.
    private let isTraced: Bool

    /// Begins the interval now, in the intent's turn.
    ///
    /// - Parameters:
    ///   - kind: What the new tab shows.
    ///   - signposter: The `create` signposter (tests pass one on their own trace runtime).
    public init(kind: Kind, signposter: Signposter = .create) {
        self.kind = kind
        self.signposter = signposter
        let begun = signposter.beginCreateTab(kind)
        interval = begun.interval
        signpostID = begun.id
        intentID = begun.intentID
        isTraced = begun.interval.isTraced
    }

    /// Where this open's steps go, during the interval and after its end: the content's own stages, which a reader
    /// groups with this pair by the intent id.
    public var scope: Scope {
        Scope(kind: kind, intentID: intentID, signpostID: signpostID.rawValue, isTraced: isTraced, signposter: signposter)
    }

    /// Whether the interval has not ended.
    public var isOpen: Bool { outcome == nil }

    /// The stand-in shows in this turn: the instant goes at the end of the Core Animation commit that carries it
    /// (`afterCommit`; nil: the main run loop's ``CommitBoundary``), unless the interval ended before or the
    /// boundary missed that commit (its time would be a later wake's). Marks once.
    public func standInShown(afterCommit: CreateTabTimings.AfterCommit? = nil) {
        guard !standInMarked, isOpen else { return }
        standInMarked = true
        let after = afterCommit ?? { CommitBoundary().after($0) }
        after { [self] commit in
            guard commit == .committed, isOpen, let interval else { return }
            signposter.createTabStandIn(kind, interval: interval, signpostID: signpostID, intentID: intentID)
        }
    }

    /// Ends the interval with `outcome`. Only the first call ends it: a tab that drew and then closed stays shown.
    public func end(_ outcome: Outcome) {
        guard let interval else { return }
        self.interval = nil
        self.outcome = outcome
        signposter.endCreateTab(interval, outcome: outcome)
    }
}

extension CreateTabInterval {
    /// One open's async scope: its steps are instants on the interval's id, as Chrome writes
    /// `TRACE_EVENT_NESTABLE_ASYNC_INSTANT` steps with the id of their async event (base/trace_event/trace_event.h).
    /// A step may come after the pair's end (a loading cover's fade ends after the first paint) and keeps the id.
    /// Content made with no open (a prewarmed page, a restored pane) has no scope, so it writes no step.
    public nonisolated struct Scope: Sendable {
        /// What the open shows.
        public let kind: Kind
        /// The open's intent id: the pair's async id and each step's `arg1`.
        public let intentID: UInt64
        /// The interval's `OSSignpostID` raw value: each step's log event is on it.
        let signpostID: UInt64
        /// Whether the begin wrote a ring record (each step writes one only then).
        let isTraced: Bool
        let signposter: Signposter

        /// Writes one step named `name` (a ``SignpostCategory/create`` name, ``SignpostName/createTab``): a log event
        /// on the interval's id with `message`, and, when the begin wrote a ring record, a ring instant with `arg0`
        /// and the intent id in `arg1`. One log event per step of one open: never per frame.
        ///
        /// - Parameters:
        ///   - name: The step's catalog name.
        ///   - message: Public text for the log system (fixed names, never user content).
        ///   - arg0: The ring record's first number (the name's doc comment says what it holds).
        public func event(_ name: SignpostName, _ message: String, arg0: UInt64) {
            assert(name.category == .create, "\(name) is not a create step")
            signposter.signposter.emitEvent(name.staticName, id: OSSignpostID(signpostID), "\(message, privacy: .public)")
            if isTraced { signposter.trace.event(name, arg0: arg0, arg1: intentID) }
        }
    }
}

extension Signposter {
    /// Begins a ``SignpostName/createTab`` interval: the log system's (`kind=<kind>`), the MetricKit mirror's and,
    /// while the `create` category is on, the ring's async begin keyed by the intent id (the begin's
    /// `OSSignpostID`, as every async ring slice is keyed, ``asyncID(_:beginNanos:)``).
    func beginCreateTab(_ kind: CreateTabInterval.Kind) -> (interval: SignpostInterval, id: OSSignpostID, intentID: UInt64) {
        assert(SignpostName.createTab.category == category, "create.tab is not in category \(category)")
        let id = signposter.makeSignpostID()
        let beginNanos = clock.nowNanos()
        let state = signposter.beginInterval(SignpostName.createTab.staticName, id: id, "kind=\(kind.name, privacy: .public)")
        let ring = traceBegin(.createTab, id: id, beginNanos: beginNanos, arg0: kind.traceCode)
        let interval = SignpostInterval(state: state, metricKitID: mirror.begin(.createTab), beginUptimeNanos: beginNanos, ring: ring)
        return (interval, id, Self.asyncID(id, beginNanos: beginNanos))
    }

    /// Ends a ``SignpostName/createTab`` interval with `outcome=<outcome>`; the ring's AE holds the outcome.
    func endCreateTab(_ interval: SignpostInterval, outcome: CreateTabInterval.Outcome) {
        signposter.endInterval(SignpostName.createTab.staticName, interval.state, "outcome=\(outcome.name, privacy: .public)")
        if outcome == .shown, let id = interval.metricKitID { mirror.end(.createTab, id: id) } // closed, hidden, missed: no sample
        closeInterval(.createTab, interval, arg0: outcome.rawValue)
    }

    /// The stand-in commit of an open ``SignpostName/createTab`` interval: a log event on the interval's id and, when
    /// its begin wrote a ring record, a ring instant with the kind in `arg0` and the intent id in `arg1`.
    func createTabStandIn(_ kind: CreateTabInterval.Kind, interval: SignpostInterval, signpostID: OSSignpostID, intentID: UInt64) {
        signposter.emitEvent(SignpostName.createTab.staticName, id: signpostID, "stand_in kind=\(kind.name, privacy: .public)")
        if interval.isTraced { trace.event(.createTab, arg0: kind.traceCode, arg1: intentID) }
    }
}
