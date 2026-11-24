import Foundation

/// Agent Alarms (Settings → Notifications → Agent Alarms): an AlarmKit alarm, the kind that
/// rings through Silent and Focus, when a coding agent is stuck on the person. This file is the
/// rule, Foundation only, so the app, the notification service extension and the Linux tests run
/// the same code: which events ring, the one global 30 second debounce, and the store the app
/// and the extension share. `AgentAlarmRinger` is the AlarmKit side.
public enum AgentAlarmTrigger: String, CaseIterable, Codable, Sendable, Identifiable {
    /// An agent asks to run a tool (acpmux permission request).
    case permission
    /// An agent asks the person a question.
    case question
    /// A terminal agent (Claude Code or Codex in a terminal tab) waits for input in its TUI.
    case needsInput
    /// An agent's turn stopped with an error: it crashed, lost its process or gave up.
    case agentFailed
    /// A Mac this phone was linked to stopped answering for a minute while cmux was open:
    /// its agents are out of reach. Off by default, since a phone's own network drops look the same.
    case macOffline

    public var id: String { rawValue }

    /// Whether a fresh install rings for it once Agent Alarms is on.
    public var onByDefault: Bool { self != .macOffline }

    public var title: String {
        switch self {
        case .permission: String(localized: "Permission requests")
        case .question: String(localized: "Questions")
        case .needsInput: String(localized: "Terminal agents waiting")
        case .agentFailed: String(localized: "Agent stopped or crashed")
        case .macOffline: String(localized: "Mac went offline")
        }
    }

    public var symbol: String {
        switch self {
        case .permission: "hand.raised"
        case .question: "questionmark.bubble"
        case .needsInput: "terminal"
        case .agentFailed: "exclamationmark.triangle"
        case .macOffline: "desktopcomputer.trianglebadge.exclamationmark"
        }
    }

    /// The alarm's title on the lock screen. `name` is the agent's (the Mac's for `macOffline`).
    public func alarmTitle(agent name: String?) -> String {
        let given = name.flatMap { $0.isEmpty ? nil : $0 }
        if self == .macOffline {
            return given.map { String(localized: "\($0) went offline") } ?? String(localized: "Your Mac went offline")
        }
        let agent = given ?? String(localized: "Your agent")
        return switch self {
        case .permission: String(localized: "\(agent) needs permission")
        case .question: String(localized: "\(agent) has a question")
        case .needsInput: String(localized: "\(agent) is waiting for you")
        case .agentFailed: String(localized: "\(agent) stopped")
        case .macOffline: String(localized: "Your Mac went offline")
        }
    }

    /// The trigger a push rings, or nil for one that never does (a finished turn, Chief, a plain
    /// terminal notification).
    public init?(payload: PushPayload) {
        switch payload.kind {
        case .permission: self = .permission
        case .question: self = .question
        case .failed: self = .agentFailed
        case .terminal:
            switch payload.state {
            case .waiting?: self = .needsInput
            case .failed?: self = .agentFailed
            default: return nil
            }
        case .completed, .chief: return nil
        }
    }
}

/// What the person chose. Off until they turn it on: turning it on is what asks iOS for alarm
/// permission, which iOS asks only once.
public struct AgentAlarmPreferences: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var triggers: Set<AgentAlarmTrigger>

    public init(enabled: Bool = false, triggers: Set<AgentAlarmTrigger> = Set(AgentAlarmTrigger.allCases.filter(\.onByDefault))) {
        self.enabled = enabled
        self.triggers = triggers
    }

    public func rings(_ trigger: AgentAlarmTrigger) -> Bool { enabled && triggers.contains(trigger) }
}

/// What rang and when, shared by the app and the extension so the debounce is one clock for both.
public struct AgentAlarmLedger: Codable, Sendable, Equatable {
    /// The last alarm that rang (or was handed to AlarmKit), from any process.
    public var lastRang: Date?
    /// Events already handled (rung or debounced), so one ask seen as a push and again in the
    /// Feed rings once. Kept a day.
    public var seen: [String: Date]
    /// The alarm AlarmKit holds for an event, so it stops when the ask closes.
    public var alarms: [String: UUID]
    /// The newest decisions first (Settings → Agent Alarms → Recent), at most `historyLimit`.
    public var history: [AgentAlarmLogEntry]

    public init(lastRang: Date? = nil, seen: [String: Date] = [:], alarms: [String: UUID] = [:], history: [AgentAlarmLogEntry] = []) {
        self.lastRang = lastRang
        self.seen = seen
        self.alarms = alarms
        self.history = history
    }

    enum CodingKeys: String, CodingKey { case lastRang, seen, alarms, history }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastRang = try c.decodeIfPresent(Date.self, forKey: .lastRang)
        seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
        alarms = try c.decodeIfPresent([String: UUID].self, forKey: .alarms) ?? [:]
        history = try c.decodeIfPresent([AgentAlarmLogEntry].self, forKey: .history) ?? []
    }

    public static let historyLimit = 20

    mutating func log(_ entry: AgentAlarmLogEntry) {
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    /// Seconds left before another alarm may ring, or nil when one may ring now.
    public func debounceRemaining(now: Date) -> TimeInterval? {
        guard let lastRang else { return nil }
        let since = now.timeIntervalSince(lastRang)
        return since < AgentAlarmGate.debounce ? AgentAlarmGate.debounce - max(since, 0) : nil
    }

    static let seenLifetime: TimeInterval = 24 * 60 * 60
    static let seenLimit = 500

    mutating func prune(now: Date) {
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.seenLifetime }
        if seen.count > Self.seenLimit {
            let keep = seen.sorted { $0.value > $1.value }.prefix(Self.seenLimit)
            seen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        alarms = alarms.filter { seen[$0.key] != nil }
    }
}

/// Where an event was seen.
public enum AgentAlarmSource: String, Codable, Sendable {
    /// The notification service extension: cmux in the background, suspended or not running.
    case serviceExtension
    /// A push while cmux is in front (`willPresent`).
    case foregroundPush
    /// The live Feed while cmux runs (an ask or an error that came over the Mac link).
    case feed
    /// The phone's own watch of its Macs' links.
    case macLink
    /// Settings → Agent Alarms → Test Alarm.
    case test

    public var title: String {
        switch self {
        case .serviceExtension: String(localized: "push, cmux not open")
        case .foregroundPush: String(localized: "push, cmux open")
        case .feed: String(localized: "live Feed")
        case .macLink: String(localized: "Mac link")
        case .test: String(localized: "test")
        }
    }
}

/// One decision, for the Recent list.
public struct AgentAlarmLogEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case rang, debounced, duplicate, notAllowed, failed
    }

    public var id: UUID
    public var at: Date
    public var trigger: AgentAlarmTrigger
    public var source: AgentAlarmSource
    public var outcome: Outcome
    public var title: String
    /// Debounced: the seconds that were left of the window.
    public var wait: TimeInterval?

    public init(id: UUID = UUID(), at: Date, trigger: AgentAlarmTrigger, source: AgentAlarmSource, outcome: Outcome,
                title: String, wait: TimeInterval? = nil) {
        self.id = id
        self.at = at
        self.trigger = trigger
        self.source = source
        self.outcome = outcome
        self.title = title
        self.wait = wait
    }
}

/// The gate's answer for one event.
public enum AgentAlarmDecision: Equatable, Sendable {
    case ring
    /// Agent Alarms is off.
    case off
    /// This trigger is off.
    case triggerOff
    /// Already rang (or was debounced) for this event.
    case duplicate
    /// Another alarm rang less than 30 seconds ago; `wait` is what is left of the window.
    case debounced(wait: TimeInterval)

    public var rings: Bool { self == .ring }
}

/// The rule: one alarm per event, and never two within 30 seconds of each other, whatever
/// triggers them and whichever process (app or extension) sees them.
public enum AgentAlarmGate {
    /// The user's rule: at most one alarm in any 30 seconds.
    public static let debounce: TimeInterval = 30

    public static func decide(_ trigger: AgentAlarmTrigger, key: String, now: Date,
                              preferences: AgentAlarmPreferences, ledger: AgentAlarmLedger) -> AgentAlarmDecision {
        guard preferences.enabled else { return .off }
        guard preferences.triggers.contains(trigger) else { return .triggerOff }
        if ledger.seen[key] != nil { return .duplicate }
        if let last = ledger.lastRang {
            let since = now.timeIntervalSince(last)
            // A clock moved backwards counts as just rung: wait out the window rather than ring twice.
            if since < debounce { return .debounced(wait: debounce - max(since, 0)) }
        }
        return .ring
    }

    /// Decides and records in one step. A debounced event is recorded too, so the same ask
    /// coming back after the window (its Feed row after its push) doesn't ring late.
    public static func claim(_ trigger: AgentAlarmTrigger, key: String, now: Date,
                             preferences: AgentAlarmPreferences, ledger: inout AgentAlarmLedger) -> AgentAlarmDecision {
        ledger.prune(now: now)
        let decision = decide(trigger, key: key, now: now, preferences: preferences, ledger: ledger)
        switch decision {
        case .ring:
            ledger.lastRang = now
            ledger.seen[key] = now
        case .debounced, .duplicate:
            ledger.seen[key] = ledger.seen[key] ?? now
        case .off, .triggerOff:
            break
        }
        return decision
    }

    /// One event's key, the same for its push and its Feed row: an ask by its acpmux permission
    /// id (the Feed's `ask-<id>`), anything else by the Mac's event id.
    public static func key(permissionID: String?, eventID: String?, fallback: String?) -> String? {
        if let permissionID, !permissionID.isEmpty { return "ask:\(permissionID)" }
        if let eventID, !eventID.isEmpty { return "event:\(eventID)" }
        if let fallback, !fallback.isEmpty { return "other:\(fallback)" }
        return nil
    }

    public static func key(_ payload: PushPayload) -> String? {
        key(permissionID: payload.permissionId, eventID: payload.eventId, fallback: payload.notificationId)
    }
}

/// The preferences and the ledger, where the app and its notification service extension both
/// read them: the push keychain group every build has (`PushSharedPreference`), else the app's
/// defaults (a build without the group, whose extension then can't ring).
// crash-allow: its stores are thread safe (UserDefaults, and the keychain store is Sendable); the struct holds no mutable state of its own
public struct AgentAlarmStore: @unchecked Sendable {
    public static let preferencesAccount = "preference.agentAlarms"
    public static let ledgerAccount = "state.agentAlarms"

    public var keychain: (any PushSecretStore)?
    public var defaults: UserDefaults?

    public init(keychain: (any PushSecretStore)?, defaults: UserDefaults?) {
        self.keychain = keychain
        self.defaults = defaults
    }

    public static func live(bundle: Bundle = .main) -> AgentAlarmStore {
        let keychain = PushKeychainStore.current(bundle: bundle)
        return AgentAlarmStore(keychain: keychain, defaults: keychain == nil ? .standard : nil)
    }

    /// True when the extension reads the same store as the app (alarms while cmux isn't running).
    public var sharedWithExtension: Bool { keychain != nil }

    public func preferences() -> AgentAlarmPreferences { read(Self.preferencesAccount) ?? AgentAlarmPreferences() }
    public func save(_ preferences: AgentAlarmPreferences) { write(preferences, Self.preferencesAccount) }

    public func ledger() -> AgentAlarmLedger { read(Self.ledgerAccount) ?? AgentAlarmLedger() }
    public func save(_ ledger: AgentAlarmLedger) { write(ledger, Self.ledgerAccount) }

    /// The gate over the stored state; records the event (and a Recent line) when it is handled.
    /// `overrideTrigger`: Test Alarm rings whichever triggers are on (Agent Alarms itself still must be).
    public func claim(_ trigger: AgentAlarmTrigger, key: String, source: AgentAlarmSource, title: String,
                      overrideTrigger: Bool = false, now: Date = Date()) -> AgentAlarmDecision {
        var ledger = ledger()
        var preferences = preferences()
        if overrideTrigger { preferences.triggers.insert(trigger) }
        let decision = AgentAlarmGate.claim(trigger, key: key, now: now, preferences: preferences, ledger: &ledger)
        let outcome: AgentAlarmLogEntry.Outcome? = switch decision {
        case .ring: .rang
        case .debounced: .debounced
        // A push and its Feed row are one event: the second sighting is not news.
        case .duplicate, .off, .triggerOff: nil
        }
        if let outcome {
            var wait: TimeInterval?
            if case .debounced(let left) = decision { wait = left }
            ledger.log(AgentAlarmLogEntry(at: now, trigger: trigger, source: source, outcome: outcome, title: title, wait: wait))
        }
        save(ledger)
        return decision
    }

    /// AlarmKit refused an alarm the gate let through: the Recent line says so.
    public func recordFailure(_ trigger: AgentAlarmTrigger, source: AgentAlarmSource, title: String, notAllowed: Bool, now: Date = Date()) {
        var ledger = ledger()
        ledger.log(AgentAlarmLogEntry(at: now, trigger: trigger, source: source, outcome: notAllowed ? .notAllowed : .failed, title: title))
        save(ledger)
    }

    /// Clears the Recent list and the debounce (Settings → Agent Alarms → Clear).
    public func resetLedger() { save(AgentAlarmLedger()) }

    public func remember(alarm: UUID, for key: String) {
        var ledger = ledger()
        ledger.alarms[key] = alarm
        save(ledger)
    }

    /// The alarms of events that closed, removed from the ledger.
    public func takeAlarms(for keys: some Sequence<String>) -> [UUID] {
        var ledger = ledger()
        let ids = keys.compactMap { ledger.alarms.removeValue(forKey: $0) }
        if !ids.isEmpty { save(ledger) }
        return ids
    }

    private func read<T: Decodable>(_ account: String) -> T? {
        let data: Data? = if let keychain { try? keychain.read(account) } else { defaults?.data(forKey: "cmuxMobile.push.\(account)") }
        return data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func write(_ value: some Encodable, _ account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        if let keychain { try? keychain.write(data, account: account) } else { defaults?.set(data, forKey: "cmuxMobile.push.\(account)") }
    }
}
