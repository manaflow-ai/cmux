public import Foundation

/// Which workspaces are idle enough to archive, and when to look again
/// (plans/cmux-next/auto-archive-DESIGN.md). The rules live in Rust (`cmux-layout-reducer`
/// `auto_archive`, op `auto_archive_plan`); this is the app's side of the call. The App gathers one
/// ``Candidate`` per placed workspace and the groups' rules, reads the clock once, and performs the
/// ``Plan``. The planner never archives anything that is pinned, shown in a window, running a
/// command or an agent turn, or asking for the person (unread, waiting, error), and never a
/// workspace whose nearest group says Never. One call per background pass, sweep or review list.
public nonisolated struct AutoArchivePlanner: Sendable {
    public init() {}

    /// One placed workspace and what keeps it.
    public nonisolated struct Candidate: Hashable, Sendable {
        /// The sidebar document item that places it (what `archive` takes).
        public var item: String
        /// The workspace's id (for the toast's and card's names and the activity ledger).
        public var workspace: String
        /// The name the card lists.
        public var title: String
        /// The newest sign of use: shown, typed in, output, an agent update, a notification. Nil:
        /// never seen; the ledger records the first sight, so a workspace is never idle on arrival.
        public var lastActive: Date?
        /// Its group items, nearest first (the nearest group with a rule decides).
        public var groups: [String]
        /// Pinned (in Pinned or in its group): never archives.
        public var pinned: Bool
        /// Already archived: skipped.
        public var archived: Bool
        /// Shown in a window right now: counts as used now.
        public var shown: Bool
        /// A command or an agent turn runs in one of its tabs.
        public var running: Bool
        /// It asks for the person: unread, waiting for an answer, an error.
        public var needsAttention: Bool

        public init(item: String, workspace: String, title: String = "", lastActive: Date?, groups: [String] = [],
                    pinned: Bool = false, archived: Bool = false, shown: Bool = false, running: Bool = false,
                    needsAttention: Bool = false) {
            self.item = item
            self.workspace = workspace
            self.title = title
            self.lastActive = lastActive
            self.groups = groups
            self.pinned = pinned
            self.archived = archived
            self.shown = shown
            self.running = running
            self.needsAttention = needsAttention
        }
    }

    /// What asks for the plan.
    public nonisolated enum Trigger: String, Hashable, Sendable, Encodable {
        /// The background pass (launch, a deadline, a setting change): obeys the style.
        case background
        /// Archive Idle Workspaces: the person asked, so it runs under every style, and uses the
        /// idle time even where the style would only suggest. A group's Never still keeps its members.
        case sweep
    }

    /// The result: what is due now, and when the next one comes due.
    public nonisolated struct Plan: Equatable, Sendable {
        /// The workspaces to archive (or suggest), idlest first.
        public var due: [Candidate]
        /// When the next kept-for-age workspace comes due; nil when none will without a change.
        public var nextCheck: Date?
        /// Workspaces with no activity and no ledger sight: the ledger records them at `now`.
        public var firstSight: [String]
        /// The suggestion card is snoozed (Not Now): nothing is due, and the ledger is kept as is.
        public var snoozed: Bool

        public init(due: [Candidate] = [], nextCheck: Date? = nil, firstSight: [String] = [], snoozed: Bool = false) {
            self.due = due
            self.nextCheck = nextCheck
            self.firstSight = firstSight
            self.snoozed = snoozed
        }
    }

    /// The plan for `candidates` at `now`. `seen` is the activity ledger's last sight by workspace
    /// (the newer of it and `lastActive` counts); `rules` holds each group's own rule by item id;
    /// `snoozedUntil` is the suggestion card's Not Now. A refused call plans nothing (archives nothing).
    public func plan(_ candidates: [Candidate], seen: [String: Date] = [:], rules: [String: SidebarDocAutoArchiveRule],
                     policy: AutoArchivePolicy, trigger: Trigger, now: Date, snoozedUntil: Date? = nil) -> Plan {
        let request = Request(
            candidates: candidates.map { candidate in
                Request.Candidate(lastActive: candidate.lastActive?.timeIntervalSince1970,
                                  seen: seen[candidate.workspace]?.timeIntervalSince1970, groups: candidate.groups,
                                  pinned: candidate.pinned, archived: candidate.archived, shown: candidate.shown,
                                  running: candidate.running, needsAttention: candidate.needsAttention)
            },
            rules: rules.mapValues(Request.Rule.init),
            policy: Request.Policy(style: policy.style.rawValue, idleDays: policy.idleDays),
            trigger: trigger, now: now.timeIntervalSince1970, snoozedUntil: snoozedUntil?.timeIntervalSince1970)
        guard let reply = RustSidebarClient.call("auto_archive_plan", request, as: Reply.self) else { return Plan() }
        let pick = { (indices: [Int]) in indices.compactMap { candidates.indices.contains($0) ? candidates[$0] : nil } }
        return Plan(due: pick(reply.due), nextCheck: reply.nextCheck.map(Date.init(timeIntervalSince1970:)),
                    firstSight: pick(reply.firstSight).map(\.workspace), snoozed: reply.snoozed)
    }

    // MARK: - Wire (`auto_archive::Request` and `Plan`)

    private struct Request: Encodable {
        struct Candidate: Encodable {
            var lastActive: Double?
            var seen: Double?
            var groups: [String]
            var pinned, archived, shown, running, needsAttention: Bool
            enum CodingKeys: String, CodingKey {
                case lastActive = "last_active", seen, groups, pinned, archived, shown, running, needsAttention = "needs_attention"
            }
        }

        struct Policy: Encodable {
            var style: String
            var idleDays: Double
            enum CodingKeys: String, CodingKey { case style, idleDays = "idle_days" }
        }

        /// `"never"` or whole hours, as the document stores it.
        struct Rule: Encodable {
            var rule: SidebarDocAutoArchiveRule
            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch rule {
                case .never: try container.encode("never")
                case let .afterHours(hours): try container.encode(hours)
                }
            }
        }

        var candidates: [Candidate]
        var rules: [String: Rule]
        var policy: Policy
        var trigger: Trigger
        var now: Double
        var snoozedUntil: Double?
        enum CodingKeys: String, CodingKey { case candidates, rules, policy, trigger, now, snoozedUntil = "snoozed_until" }
    }

    private struct Reply: Decodable {
        var due: [Int]
        var nextCheck: Double?
        var firstSight: [Int]
        var snoozed: Bool
        enum CodingKeys: String, CodingKey { case due, nextCheck = "next_check", firstSight = "first_sight", snoozed }
    }
}
