package import CmuxNextCompat

/// The kinds of content cmux can discard (plans/cmux-next/chrome-parity/p07-memory.md, section 3.C).
/// Chrome discards only tabs; cmux has more kinds of hidden content that hold memory.
package enum ContentKind: String, CaseIterable, Hashable, Sendable {
    /// A browser tab: a CEF or WebKit page, or one of the other `BrowserTab` conformers.
    case browser
    /// An agent chat page.
    case agentPage = "agent_page"
    /// A cmux page in a tab (`InternalPageID`).
    case internalPage = "internal_page"
    /// A window's top page (`TopPageHost`).
    case topPage = "top_page"
    case conversation
    /// A terminal's render state (its Ghostty surface and GPU drawables).
    case terminalSurface = "terminal_surface"
    /// A hidden workspace's mounted content.
    case parkedWorkspace = "parked_workspace"
    /// A page shown over the window (icon picker, update island, extensions panel).
    case overlayPage = "overlay_page"
    /// A right sidebar section.
    case sidebarSection = "sidebar_section"
}

/// Why content was discarded (Chrome's `DiscardReason`, chrome/browser/resource_coordinator/lifecycle_unit_types.h).
package enum DiscardReason: String, Hashable, Sendable {
    /// Hidden past its timeout with no memory pressure (Memory Saver).
    case proactive
    /// Taken under memory pressure.
    case urgent
    /// The person asked for it (Hibernate Tab).
    case external
    /// A frozen page whose memory kept growing.
    case frozenWithGrowingMemory = "frozen_with_growing_memory"

    /// The reason a planner pass at `pressure` discards for; `user` when the person asked.
    package init(pressure: MemoryPressureLevel, user: Bool) {
        if user {
            self = .external
        } else {
            self = pressure == .normal ? .proactive : .urgent
        }
    }
}

/// One planner for every kind of content (p07-memory.md section 3.C). This part keeps the
/// planner's last inputs for each content its owners report, which `debug.discards` shows as
/// chrome://discards shows tabs (chrome/browser/ui/webui/discards/discards_ui.cc): visibility,
/// lifecycle state, whether it can be discarded and why not, the last discard's reason and how
/// often it woke. Owners report events; nothing here walks the session, and reading the rows is
/// O(contents tracked).
package struct ContentDiscardPlanner: Sendable {
    /// A content's lifecycle state (Chrome's LifecycleUnitState: active, frozen, discarded).
    package enum State: String, Hashable, Sendable {
        case live, frozen, discarded
    }

    /// What an owner reports about content `key`.
    package enum Event: Hashable, Sendable {
        /// It shows. A verdict made while it was hidden no longer applies.
        case shown(String, ContentKind)
        /// It stopped showing.
        case hidden(String, ContentKind)
        /// A planner pass judged it, counting it hidden for `hiddenFor` seconds (the planner's
        /// clock wins: an agent's call restarts it).
        case planned(String, ContentKind, hiddenFor: Double, CanDiscardResult)
        /// The owner starts to discard it for a reason; `discarded` completes it.
        case discarding(String, ContentKind, DiscardReason)
        /// The discard `discarding` started is done.
        case discarded(String)
        /// Discarded content was rebuilt.
        case woke(String)
        /// Live content froze (true) or thawed (false).
        case frozen(String, Bool)
        /// It closed.
        case removed(String)
    }

    /// One content as `debug.discards` shows it.
    package struct Row: Equatable, Sendable {
        package var key: String
        package var kind: ContentKind
        package var visible: Bool
        /// Seconds since it was last visible; nil while it shows.
        package var hiddenFor: Double?
        package var state: State
        package var eligibility: CanDiscardResult
        /// Why it was last discarded; nil when it never was.
        package var lastDiscardReason: DiscardReason?
        /// Times it was rebuilt after a discard.
        package var wakeCount: Int
    }

    /// One kind as `debug.discards` shows it: whether an owner reports its contents, and how many.
    package struct KindSummary: Equatable, Sendable {
        package var kind: ContentKind
        package var tracked: Bool
        package var contents: Int
        package var discarded: Int
        /// Why none of its contents can be discarded; nil when an owner tracks the kind.
        package var reason: CannotDiscardReason? { tracked ? nil : .noPolicy }
    }

    private struct Input: Sendable {
        var kind: ContentKind
        var visible = false
        var hiddenSince: ContinuousClock.Instant?
        var state = State.live
        var verdict: CanDiscardResult?
        var pendingDiscard: DiscardReason?
        var lastDiscardReason: DiscardReason?
        var wakeCount = 0
    }

    private var inputs: [String: Input] = [:]
    /// The kinds an owner reports.
    package private(set) var trackedKinds: Set<ContentKind> = []

    package init() {}

    /// A planner whose owners report the contents of `kinds`.
    package init(tracking kinds: ContentKind...) {
        trackedKinds = Set(kinds)
    }

    /// An owner reports the contents of `kind` from now on.
    package mutating func track(_ kind: ContentKind) {
        trackedKinds.insert(kind)
    }

    /// Applies an owner's report at `now`.
    package mutating func note(_ event: Event, at now: ContinuousClock.Instant) {
        switch event {
        case .shown(let key, let kind):
            update(key, kind) {
                $0.visible = true
                $0.hiddenSince = nil
                $0.verdict = nil
            }
        case .hidden(let key, let kind):
            update(key, kind) {
                $0.visible = false
                $0.hiddenSince = now
                $0.verdict = nil
            }
        case .planned(let key, let kind, let hiddenFor, let verdict):
            update(key, kind) {
                $0.visible = false
                $0.hiddenSince = now - .seconds(hiddenFor.isFinite ? max(hiddenFor, 0) : 0)
                $0.verdict = verdict
            }
        case .discarding(let key, let kind, let reason):
            update(key, kind) { $0.pendingDiscard = reason }
        case .discarded(let key):
            guard var input = inputs[key] else { return }
            input.state = .discarded
            input.lastDiscardReason = input.pendingDiscard ?? input.lastDiscardReason
            input.pendingDiscard = nil
            input.verdict = nil
            inputs[key] = input
        case .woke(let key):
            guard var input = inputs[key], input.state == .discarded else { return }
            input.state = .live
            input.wakeCount += 1
            inputs[key] = input
        case .frozen(let key, let isFrozen):
            guard var input = inputs[key], input.state != .discarded else { return }
            input.state = isFrozen ? .frozen : .live
            inputs[key] = input
        case .removed(let key):
            inputs[key] = nil
        }
    }

    /// Every reported content at `now`, ordered by key.
    package func rows(now: ContinuousClock.Instant) -> [Row] {
        inputs.map { Self.row($0.key, $0.value, now: now) }.sorted { $0.key < $1.key }
    }

    /// Content `key` at `now`; nil when no owner reported it.
    package func row(_ key: String, now: ContinuousClock.Instant) -> Row? {
        inputs[key].map { Self.row(key, $0, now: now) }
    }

    /// Each of the nine kinds, in declaration order.
    package var kinds: [KindSummary] {
        var contents: [ContentKind: Int] = [:]
        var discarded: [ContentKind: Int] = [:]
        for input in inputs.values {
            contents[input.kind, default: 0] += 1
            if input.state == .discarded { discarded[input.kind, default: 0] += 1 }
        }
        return ContentKind.allCases.map {
            KindSummary(kind: $0, tracked: trackedKinds.contains($0), contents: contents[$0] ?? 0, discarded: discarded[$0] ?? 0)
        }
    }

    private static func row(_ key: String, _ input: Input, now: ContinuousClock.Instant) -> Row {
        Row(key: key, kind: input.kind, visible: input.visible,
            hiddenFor: input.visible ? nil : input.hiddenSince.map { seconds(now - $0) },
            state: input.state, eligibility: eligibility(input),
            lastDiscardReason: input.lastDiscardReason, wakeCount: input.wakeCount)
    }

    /// Chrome's order (discard_eligibility_policy.cc `CanDiscard`): discarded content is
    /// disallowed, then visible content is protected, then the planner's verdict applies.
    private static func eligibility(_ input: Input) -> CanDiscardResult {
        if input.state == .discarded { return .disallowed(.alreadyDiscarded) }
        if input.visible { return .protected(.visible) }
        return input.verdict ?? .protected(.notPlanned)
    }

    private mutating func update(_ key: String, _ kind: ContentKind, _ change: (inout Input) -> Void) {
        var input = inputs[key] ?? Input(kind: kind)
        input.kind = kind
        change(&input)
        inputs[key] = input
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
