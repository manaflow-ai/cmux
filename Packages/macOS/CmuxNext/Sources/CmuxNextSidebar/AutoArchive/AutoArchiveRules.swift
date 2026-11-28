import Foundation

/// Auto-archive's rules, which are Rust's: the document marks a pass reads and the bulk archive rows
/// (`sidebar_archive_marks`, cmux-layout-reducer sidebar_archive_marks.rs) and what the coordinator does
/// around a plan (`auto_archive_ledger`, auto_archive_ledger.rs: the sights a plan records, the pass's
/// action, the card's names, what comes back when shown, restores and Not Now). The coordinator keeps the
/// clock, the deadlines, the toasts and the sends. Each call returns nil when the FFI refuses it.
nonisolated enum AutoArchiveRules {
    // MARK: - sidebar_archive_marks

    /// The marks `plan` lays over each candidate, and every group's rule.
    static func marks(_ records: SidebarDocRecords, candidates: [AutoArchivePlanner.Candidate], shown: Set<String>) -> Marks? {
        let request = MarksRequest(
            records: Self.records(records, items: candidates.map(\.item)),
            candidates: candidates.map { MarkCandidate(item: $0.item, workspace: $0.workspace, shown: $0.shown, archived: $0.archived, pinned: $0.pinned) },
            shown: Array(shown))
        guard let reply = RustSidebarClient.call("sidebar_archive_marks", request, as: Marks.self),
              reply.marks.count == candidates.count else { return nil }
        return reply
    }

    /// The items Archive Other Workspaces, Above or Below take, in order, once each.
    static func archivable(_ records: SidebarDocRecords, items: [String?]) -> [String]? {
        let request = ArchivableRequest(records: Self.records(records, items: items.compactMap { $0 }), items: items)
        return RustSidebarClient.call("sidebar_archive_marks", request, as: ArchivableReply.self)?.archivable
    }

    /// The Archived page's rows (each candidate's index and its last use), last used first.
    static func archived(_ records: SidebarDocRecords, candidates: [AutoArchivePlanner.Candidate], seen: [String: Double]) -> [ArchivedRow]? {
        let request = ArchivedRequest(
            records: Self.records(records, items: candidates.map(\.item)),
            candidates: candidates.map { Used(item: $0.item, lastActive: $0.lastActive?.timeIntervalSince1970, seen: seen[$0.workspace]) })
        return RustSidebarClient.call("sidebar_archive_marks", request, as: ArchivedReply.self)?.rows
    }

    /// The records of `items` and of every group (the only items a parent chain reaches), by id.
    static func records(_ records: SidebarDocRecords, items: some Sequence<String>) -> [String: Record] {
        var out: [String: Record] = [:]
        func add(_ item: SidebarDocItem) {
            out[item.id] = Record(section: item.section, parent: item.parent, archived: item.archived,
                                  pinnedInGroup: item.pinnedInGroup, group: item.body.isGroup,
                                  autoArchive: item.body.isGroup ? item.autoArchive.map(Rule.init) : nil)
        }
        for item in records.items.values where item.body.isGroup { add(item) }
        for id in items { if let item = records.items[id] { add(item) } }
        return out
    }

    // MARK: - auto_archive_ledger

    /// What a background pass does with `due` workspaces due, the plan's next check and the clock.
    static func pass(_ policy: AutoArchivePolicy, due: Int, nextCheck: Date?, now: Date) -> Pass? {
        RustSidebarClient.call("auto_archive_ledger", PassRequest(
            style: policy.style.rawValue, idleDays: policy.idleDays, due: due,
            nextCheck: nextCheck?.timeIntervalSince1970, now: now.timeIntervalSince1970), as: Pass.self)
    }

    /// The ledger after a plan: first sights recorded and, unless snoozed, gone workspaces and items dropped.
    static func planned(_ ledger: AutoArchiveLedger, firstSight: [String], snoozed: Bool, workspaces: Set<String>,
                        items: Set<String>, now: Date) -> (ledger: AutoArchiveLedger, dirty: Bool)? {
        let request = PlannedRequest(ledger: ledger, firstSight: firstSight, snoozed: snoozed, workspaces: Array(workspaces),
                                     items: Array(items), now: now.timeIntervalSince1970)
        return RustSidebarClient.call("auto_archive_ledger", request, as: PlannedReply.self).map { ($0.ledger, $0.dirty) }
    }

    /// The card's names: the first few titles, and how many more there are.
    static func card(_ titles: [String]) -> (lines: [String], more: Int?)? {
        RustSidebarClient.call("auto_archive_ledger", CardRequest(titles: titles), as: CardReply.self).map { ($0.lines, $0.more) }
    }

    /// The windows show `shown`: each is seen, and the auto-archived items still archived come back (`back`).
    static func shown(_ ledger: AutoArchiveLedger, _ shown: [Shown], now: Date) -> (ledger: AutoArchiveLedger, back: [String], dirty: Bool)? {
        let request = ShownRequest(ledger: touching(ledger, shown.map(\.workspace)), shown: shown, now: now.timeIntervalSince1970)
        guard let reply = RustSidebarClient.call("auto_archive_ledger", request, as: ShownReply.self) else { return nil }
        return (merged(ledger, reply.ledger), reply.back, reply.dirty)
    }

    /// The ledger after auto-archive archived `items`.
    static func archived(_ ledger: AutoArchiveLedger, items: [String]) -> AutoArchiveLedger? {
        let request = ArchivedLedgerRequest(ledger: touching(ledger, []), items: items)
        return RustSidebarClient.call("auto_archive_ledger", request, as: LedgerReply.self).map { merged(ledger, $0.ledger) }
    }

    /// The ledger after `items` were restored; each of `workspaces` counts as used now.
    static func restored(_ ledger: AutoArchiveLedger, items: [String], workspaces: [String], now: Date) -> AutoArchiveLedger? {
        let request = RestoredRequest(ledger: touching(ledger, workspaces), items: items, workspaces: workspaces, now: now.timeIntervalSince1970)
        return RustSidebarClient.call("auto_archive_ledger", request, as: LedgerReply.self).map { merged(ledger, $0.ledger) }
    }

    /// The ledger after Not Now, and when the next pass runs (seconds from now).
    static func snoozed(_ ledger: AutoArchiveLedger, now: Date) -> (ledger: AutoArchiveLedger, recheckAfter: Double)? {
        let request = SnoozedRequest(ledger: touching(ledger, []), now: now.timeIntervalSince1970)
        return RustSidebarClient.call("auto_archive_ledger", request, as: SnoozedReply.self).map { (merged(ledger, $0.ledger), $0.recheckAfter) }
    }

    /// What the card's Archive takes: its `items` still due now, in order.
    static func stillDue(_ items: [String], due: [String]) -> [String]? {
        RustSidebarClient.call("auto_archive_ledger", StillDueRequest(items: items, due: due), as: StillDueReply.self)?.items
    }

    /// `ledger` with only the sights of `workspaces`: the ops that record sights touch no other, so the rest stays
    /// here and a call stays as small as its change (a show runs on every switch).
    private static func touching(_ ledger: AutoArchiveLedger, _ workspaces: [String]) -> AutoArchiveLedger {
        var out = ledger
        out.seen = [:]
        for workspace in workspaces { if let time = ledger.seen[workspace] { out.seen[workspace] = time } }
        return out
    }

    /// `full` with a ``touching(_:_:)`` call's reply laid over it: its sights, auto-archived items and snooze.
    private static func merged(_ full: AutoArchiveLedger, _ reply: AutoArchiveLedger) -> AutoArchiveLedger {
        var out = full
        out.seen.merge(reply.seen) { _, new in new }
        out.autoArchived = reply.autoArchived
        out.snoozedUntil = reply.snoozedUntil
        return out
    }
}

// MARK: - Wire (`sidebar_archive_marks::Request` and `auto_archive_ledger::Request`)

nonisolated extension AutoArchiveRules {
    /// The fields of an item record the marks read (`sidebar_archive_marks::Record`).
    struct Record: Encodable {
        var section: String
        var parent: String?
        var archived: Bool
        var pinnedInGroup: Bool
        var group: Bool
        var autoArchive: Rule?
        enum CodingKeys: String, CodingKey {
            case section, parent, archived, pinnedInGroup = "pinned_in_group", group, autoArchive = "auto_archive"
        }
    }

    /// A group's rule on the wire: `"never"` or whole hours.
    struct Rule: Codable {
        var rule: SidebarDocAutoArchiveRule
        init(_ rule: SidebarDocAutoArchiveRule) { self.rule = rule }
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self), text == "never" {
                rule = .never
            } else {
                rule = .afterHours(try container.decode(Int.self))
            }
        }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch rule {
            case .never: try container.encode("never")
            case let .afterHours(hours): try container.encode(hours)
            }
        }
    }

    struct MarkCandidate: Encodable { var item, workspace: String; var shown, archived, pinned: Bool }
    struct MarksRequest: Encodable { var op = "marks"; var records: [String: Record]; var candidates: [MarkCandidate]; var shown: [String] }
    struct Marked: Decodable { var shown, archived, pinned: Bool; var groups: [String] }
    struct Marks: Decodable { var marks: [Marked]; var rules: [String: Rule] }

    struct ArchivableRequest: Encodable { var op = "archivable"; var records: [String: Record]; var items: [String?] }
    struct ArchivableReply: Decodable { var archivable: [String] }

    struct Used: Encodable {
        var item: String
        var lastActive, seen: Double?
        enum CodingKeys: String, CodingKey { case item, lastActive = "last_active", seen }
    }
    struct ArchivedRequest: Encodable { var op = "archived"; var records: [String: Record]; var candidates: [Used] }
    struct ArchivedRow: Decodable {
        var index: Int
        var lastActive: Double?
        enum CodingKeys: String, CodingKey { case index, lastActive = "last_active" }
    }
    struct ArchivedReply: Decodable { var rows: [ArchivedRow] }

    enum Action: String, Decodable { case archive, suggest, none }
    struct PassRequest: Encodable {
        var op = "pass"; var style: String; var idleDays: Double; var due: Int; var nextCheck: Double?; var now: Double
        enum CodingKeys: String, CodingKey { case op, style, idleDays = "idle_days", due, nextCheck = "next_check", now }
    }
    /// What a background pass does, when the next one runs (seconds from now) and the idle days the card says.
    struct Pass: Decodable {
        var action: Action
        var recheckAfter: Double?
        var days: Int
        enum CodingKeys: String, CodingKey { case action, recheckAfter = "recheck_after", days }
    }

    struct PlannedRequest: Encodable {
        var op = "planned"; var ledger: AutoArchiveLedger; var firstSight: [String]; var snoozed: Bool
        var workspaces: [String]; var items: [String]; var now: Double
        enum CodingKeys: String, CodingKey { case op, ledger, firstSight = "first_sight", snoozed, workspaces, items, now }
    }
    struct PlannedReply: Decodable { var ledger: AutoArchiveLedger; var dirty: Bool }

    struct CardRequest: Encodable { var op = "card"; var titles: [String] }
    struct CardReply: Decodable { var lines: [String]; var more: Int? }

    /// A workspace a window shows: its item (looked up only while something is auto-archived) and whether it is archived.
    struct Shown: Encodable { var workspace: String; var item: String?; var archived: Bool }
    struct ShownRequest: Encodable { var op = "shown"; var ledger: AutoArchiveLedger; var shown: [Shown]; var now: Double }
    struct ShownReply: Decodable { var ledger: AutoArchiveLedger; var back: [String]; var dirty: Bool }

    struct ArchivedLedgerRequest: Encodable { var op = "archived"; var ledger: AutoArchiveLedger; var items: [String] }
    struct RestoredRequest: Encodable { var op = "restored"; var ledger: AutoArchiveLedger; var items: [String]; var workspaces: [String]; var now: Double }
    struct LedgerReply: Decodable { var ledger: AutoArchiveLedger }

    struct SnoozedRequest: Encodable { var op = "snoozed"; var ledger: AutoArchiveLedger; var now: Double }
    struct SnoozedReply: Decodable {
        var ledger: AutoArchiveLedger; var recheckAfter: Double
        enum CodingKeys: String, CodingKey { case ledger, recheckAfter = "recheck_after" }
    }

    struct StillDueRequest: Encodable { var op = "still_due"; var items: [String]; var due: [String] }
    struct StillDueReply: Decodable { var items: [String] }
}
