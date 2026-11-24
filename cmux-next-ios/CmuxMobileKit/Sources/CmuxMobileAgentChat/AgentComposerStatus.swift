// RFD 0130, piece 1 (Leo, 2026-11-22: "hey there's space at the bottom of the composer. what else could
// we add that fits? metadata about stuff is one. because who wants to open up session info these
// days!?"): the phone's composer draws the same composer status acpmux sends the Mac's chat pane
// (`summary.composerStatus`, cmux-tui/crates/acpmux/src/protocol/composer_status.rs). acpmux decides
// the items, their order (worst first, then oldest) and which facts are live; this file only reads
// the wire and names the words. The web pane's reader is webviews/src/agent-session/acpmux/
// composerStatusModel.ts.
import Foundation

/// A session's composer footer as acpmux sends it (`composerStatus {items, facts}`).
public struct AgentComposerStatus: Hashable, Sendable {
    public var items: [Item]
    public var facts: [Fact]

    public init(items: [Item] = [], facts: [Fact] = []) {
        self.items = items
        self.facts = facts
    }

    /// One entry of the dot's rundown (acpmux `StatusItem`).
    public struct Item: Hashable, Sendable {
        public enum Level: String, Sendable, Comparable {
            case info, attention, problem
            private var rank: Int { self == .info ? 0 : self == .attention ? 1 : 2 }
            public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
        }
        /// acpmux's `StatusKind` (`machineLink`, `rateLimited`, `stuck`, ...).
        public var kind: String
        public var level: Level
        /// A string-catalog key; one this build does not know is never drawn (`words(at:)`).
        public var words: String
        public var subject: String?
        public var since: Date?
        public var until: Date?
        /// The dot shows it no earlier than this.
        public var showAt: Date?

        public init(kind: String, level: Level, words: String, subject: String? = nil,
                    since: Date? = nil, until: Date? = nil, showAt: Date? = nil) {
            self.kind = kind
            self.level = level
            self.words = words
            self.subject = subject
            self.since = since
            self.until = until
            self.showAt = showAt
        }

        /// The item's words, or nil for a key this build does not know (never the raw key).
        public var text: String? {
            let subject = subject ?? ""
            let time = until.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
            return switch words {
            case "status.machineLink.connecting": String(localized: "mobile.agentChat.composerStatus.status.machineLink.connecting", defaultValue: "Connecting to \(subject)…", bundle: .module)
            case "status.machineLink.reconnecting": String(localized: "mobile.agentChat.composerStatus.status.machineLink.reconnecting", defaultValue: "Reconnecting to \(subject)…", bundle: .module)
            case "status.machineLink.degraded": String(localized: "mobile.agentChat.composerStatus.status.machineLink.degraded", defaultValue: "\(subject) is slow to answer", bundle: .module)
            case "status.machineLink.restarting": String(localized: "mobile.agentChat.composerStatus.status.machineLink.restarting", defaultValue: "\(subject) is restarting…", bundle: .module)
            case "status.machineLink.offline": String(localized: "mobile.agentChat.composerStatus.status.machineLink.offline", defaultValue: "\(subject) is offline", bundle: .module)
            case "status.machineLink.removed": String(localized: "mobile.agentChat.composerStatus.status.machineLink.removed", defaultValue: "\(subject) was removed", bundle: .module)
            case "status.machineLink.authFailed": String(localized: "mobile.agentChat.composerStatus.status.machineLink.authFailed", defaultValue: "Sign in to \(subject) again", bundle: .module)
            case "status.machineLink.updateRequired": String(localized: "mobile.agentChat.composerStatus.status.machineLink.updateRequired", defaultValue: "\(subject) needs an update", bundle: .module)
            case "status.machineLink.offline.credentialUnavailable": String(localized: "mobile.agentChat.composerStatus.status.machineLink.offline.credentialUnavailable", defaultValue: "Can't sign in to \(subject)", bundle: .module)
            case "status.machineLink.offline.machineStopped": String(localized: "mobile.agentChat.composerStatus.status.machineLink.offline.machineStopped", defaultValue: "\(subject) is stopped", bundle: .module)
            case "status.machineLink.offline.loginNeeded": String(localized: "mobile.agentChat.composerStatus.status.machineLink.offline.loginNeeded", defaultValue: "Log in on \(subject)", bundle: .module)
            case "status.machineLink.offline.restartBudgetExceeded": String(localized: "mobile.agentChat.composerStatus.status.machineLink.offline.restartBudgetExceeded", defaultValue: "\(subject)'s agent service keeps failing", bundle: .module)
            case "status.machineLink.offline.diskFull": String(localized: "mobile.agentChat.composerStatus.status.machineLink.offline.diskFull", defaultValue: "\(subject)'s disk is full", bundle: .module)
            case "status.rateLimited.parked": String(localized: "mobile.agentChat.composerStatus.status.rateLimited.parked", defaultValue: "Rate limited", bundle: .module)
            case "status.rateLimited.until": String(localized: "mobile.agentChat.composerStatus.status.rateLimited.until", defaultValue: "Rate limited until \(time)", bundle: .module)
            case "status.stuck.harnessUnavailable": String(localized: "mobile.agentChat.composerStatus.status.stuck.harnessUnavailable", defaultValue: "\(subject) isn't available", bundle: .module)
            case "status.stuck.capacity": String(localized: "mobile.agentChat.composerStatus.status.stuck.capacity", defaultValue: "\(subject) is over capacity", bundle: .module)
            case "status.stuck.auth": String(localized: "mobile.agentChat.composerStatus.status.stuck.auth", defaultValue: "Sign in to \(subject)", bundle: .module)
            case "status.stuck.spawnFailed": String(localized: "mobile.agentChat.composerStatus.status.stuck.spawnFailed", defaultValue: "\(subject) didn't start", bundle: .module)
            case "status.harnessSandbox.failing": String(localized: "mobile.agentChat.composerStatus.status.harnessSandbox.failing", defaultValue: "\(subject)'s sandbox isn't starting", bundle: .module)
            case "status.queuePaused.paused": String(localized: "mobile.agentChat.composerStatus.status.queuePaused.paused", defaultValue: "Queue paused", bundle: .module)
            case "status.agentService.reconnecting": String(localized: "mobile.agentChat.composerStatus.status.agentService.reconnecting", defaultValue: "Reconnecting…", bundle: .module)
            case "status.restoringSessions.restoring": String(localized: "mobile.agentChat.composerStatus.status.restoringSessions.restoring", defaultValue: "Restoring sessions…", bundle: .module)
            case "status.sendsHeld.held": String(localized: "mobile.agentChat.composerStatus.status.sendsHeld.held", defaultValue: "Sending when ready", bundle: .module)
            default: nil
            }
        }
    }

    /// One piece of the footer's quiet metadata (acpmux `FooterFact`).
    public struct Fact: Hashable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case machine, folder, branch, harness, model, context, turn, subagents, queued
        }
        public var kind: Kind
        public var text: String?
        public var count: Int?
        /// The share of the context window used, 0 to 1.
        public var fraction: Double?
        public var since: Date?
        /// Worth a counter beside the dot now (acpmux decides).
        public var live: Bool

        public init(kind: Kind, text: String? = nil, count: Int? = nil, fraction: Double? = nil,
                    since: Date? = nil, live: Bool = false) {
            self.kind = kind
            self.text = text
            self.count = count
            self.fraction = fraction
            self.since = since
            self.live = live
        }

        /// The card row's label.
        public var label: String {
            switch kind {
            case .machine: String(localized: "mobile.agentChat.composerStatus.fact.machine", defaultValue: "Machine", bundle: .module)
            case .folder: String(localized: "mobile.agentChat.composerStatus.fact.folder", defaultValue: "Folder", bundle: .module)
            case .branch: String(localized: "mobile.agentChat.composerStatus.fact.branch", defaultValue: "Branch", bundle: .module)
            case .harness: String(localized: "mobile.agentChat.composerStatus.fact.harness", defaultValue: "Agent", bundle: .module)
            case .model: String(localized: "mobile.agentChat.composerStatus.fact.model", defaultValue: "Model", bundle: .module)
            case .context: String(localized: "mobile.agentChat.composerStatus.fact.context", defaultValue: "Context", bundle: .module)
            case .turn: String(localized: "mobile.agentChat.composerStatus.fact.turn", defaultValue: "Turn", bundle: .module)
            case .subagents: String(localized: "mobile.agentChat.composerStatus.fact.subagents", defaultValue: "Subagents", bundle: .module)
            case .queued: String(localized: "mobile.agentChat.composerStatus.fact.queued", defaultValue: "Queued", bundle: .module)
            }
        }

        /// The card row's value as of `now`, or nil when the fact has none.
        public func value(at now: Date) -> String? {
            switch kind {
            case .folder: text.map(Self.folderTail)
            case .context: fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
            case .turn: since.map { Duration.seconds(max(0, now.timeIntervalSince($0).rounded(.down)))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)) }
            case .subagents, .queued: count.map { $0.formatted() }
            default: text
            }
        }

        /// The last two segments of a folder path (the web card's `folderTail`).
        static func folderTail(_ path: String) -> String {
            let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            return parts.count <= 2 ? path : parts.suffix(2).joined(separator: "/")
        }
    }

    /// The items due by `now` whose words this build knows, one per kind, in acpmux's order.
    public func shownItems(at now: Date) -> [Item] {
        var seen = Set<String>()
        return items.filter { item in
            guard item.text != nil, (item.showAt ?? .distantPast) <= now else { return false }
            return seen.insert(item.kind).inserted
        }
    }

    /// The live counter for `kind` (subagents, queued): its count when acpmux marks it live.
    public func liveCount(_ kind: Fact.Kind) -> Int? {
        guard let fact = facts.first(where: { $0.kind == kind && $0.live }), let count = fact.count, count > 0 else { return nil }
        return count
    }

    /// A counter's number: up to 9, then "9+".
    public static func counterText(_ count: Int) -> String { count > 9 ? "9+" : String(max(0, count)) }
}

extension AgentComposerStatus {
    /// `composerStatus` as acpmux sent it, or nil from an older acpmux (absent, null or malformed).
    /// An item of an unknown level or a fact of an unknown kind is dropped, never guessed.
    public init?(json: JSONValue?) {
        guard let json, let items = json["items"]?.arrayValue, let facts = json["facts"]?.arrayValue else { return nil }
        func date(_ value: JSONValue?) -> Date? {
            value?.numberValue.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        }
        func text(_ value: JSONValue?) -> String? { value?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        self.items = items.compactMap { raw in
            guard let kind = text(raw["kind"]), let level = text(raw["level"]).flatMap(Item.Level.init(rawValue:)),
                  let words = raw["words"]?.stringValue else { return nil }
            return Item(kind: kind, level: level, words: words, subject: text(raw["subject"]),
                        since: date(raw["since"]), until: date(raw["until"]), showAt: date(raw["showAt"]))
        }
        self.facts = facts.compactMap { raw in
            guard let kind = text(raw["kind"]).flatMap(Fact.Kind.init(rawValue:)) else { return nil }
            var live = false
            if case .bool(true)? = raw["live"] { live = true }
            return Fact(kind: kind, text: text(raw["text"]), count: raw["count"]?.numberValue.flatMap { $0.isFinite ? Int($0) : nil },
                        fraction: raw["fraction"]?.numberValue.map { min(1, max(0, $0)) }, since: date(raw["since"]), live: live)
        }
    }
}
