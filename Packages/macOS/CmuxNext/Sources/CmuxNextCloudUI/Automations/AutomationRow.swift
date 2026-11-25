public import Foundation

/// One automation as the Automations page draws it (docs/automations-platonic-ideal.md section 8),
/// from either source: this Mac's store (`cmux automation list --json`) or cmux Cloud
/// (`automation.list` through `cloud.automation`).
public nonisolated struct AutomationRow: Equatable, Identifiable, Sendable {
    /// Where the automation runs.
    public enum Target: String, Sendable {
        /// This Mac's runner.
        case thisMac
        /// The Cloud Chief on cmux Cloud.
        case cloud
    }

    /// How the last run ended, as the page colors it.
    public enum LastResult: String, Sendable {
        case none, succeeded, failed, running, skipped
        /// It stopped on a permission prompt: unattended, it waits for the person.
        case needsYou
    }

    /// What a run does.
    public enum Kind: String, Sendable {
        /// An agent prompt: each run is an agent chat.
        case prompt
        /// A shell command: each run is a log.
        case command
        /// A Cloud Chief job.
        case chief
    }

    /// One past run, newest first on the page.
    public struct Run: Equatable, Identifiable, Sendable {
        public var id: String
        public var at: Date
        public var result: LastResult
        /// A short reason (`exit_7`, `superseded`, `machine_asleep`), or nil.
        public var reason: String?
        /// Seconds late when it started after its scheduled time.
        public var lateSeconds: Int
        /// The agent chat a prompt run is (`auto-…`), nil for a command run.
        public var session: String?
        /// The run's log file on this Mac.
        public var logPath: String?
        /// `schedule`, `manual`, `watch` or `event`.
        public var trigger: String?
        /// 0 for a first try; N for the Nth automatic retry.
        public var attempt: Int
        /// It failed after the person last looked.
        public var unread: Bool

        public init(id: String, at: Date, result: LastResult, reason: String? = nil, lateSeconds: Int = 0,
                    session: String? = nil, logPath: String? = nil, trigger: String? = nil, attempt: Int = 0, unread: Bool = false) {
            self.id = id
            self.at = at
            self.result = result
            self.reason = reason
            self.lateSeconds = lateSeconds
            self.session = session
            self.logPath = logPath
            self.trigger = trigger
            self.attempt = attempt
            self.unread = unread
        }
    }

    public var id: String
    public var name: String
    public var target: Target
    /// The trigger in words, from the CLI (`cron 0 9 * * 1-5 (local)`, `every 30m`, `When an agent goes idle`).
    public var schedule: String
    /// The prompt or command a run does.
    public var task: String
    public var enabled: Bool
    public var nextRun: Date?
    public var last: LastResult
    public var runs: [Run]
    /// Failed runs since the person last looked (`cmux automation seen`).
    public var unread: Int
    public var kind: Kind
    /// The folder a run works in.
    public var folder: String?
    /// The trigger as the store keeps it (the edit form reads it back).
    public var trigger: [String: AnySendableJSON]
    /// The run timeout in seconds.
    public var timeoutSeconds: Int?

    public init(id: String, name: String, target: Target, schedule: String, task: String, enabled: Bool,
                nextRun: Date?, last: LastResult, runs: [Run] = [], unread: Int = 0, kind: Kind = .prompt,
                folder: String? = nil, trigger: [String: AnySendableJSON] = [:], timeoutSeconds: Int? = nil) {
        self.id = id
        self.name = name
        self.target = target
        self.schedule = schedule
        self.task = task
        self.enabled = enabled
        self.nextRun = nextRun
        self.last = last
        self.runs = runs
        self.unread = unread
        self.kind = kind
        self.folder = folder
        self.trigger = trigger
        self.timeoutSeconds = timeoutSeconds
    }

    /// A failed or waiting last run, or a failure not looked at yet: the row goes to "Needs you".
    public var needsYou: Bool { enabled && (last == .failed || last == .needsYou || unread > 0) }

    /// Rows from `cmux automation list --json` (times in seconds).
    public static func local(_ data: Data) -> [AutomationRow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["automations"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let body = item["body"] as? [String: Any] ?? [:]
            let task = body["prompt"] as? String ?? body["command"] as? String ?? ""
            let last = item["last_run"] as? [String: Any]
            // The CLI says the trigger in words (`trigger_label`: "When a pull request is opened");
            // an older CLI without it falls back to the type.
            let schedule = item["trigger_label"] as? String ?? describe(item["trigger"] as? [String: Any])
            return AutomationRow(id: id, name: name, target: .thisMac, schedule: schedule,
                                 task: task, enabled: item["enabled"] as? Bool ?? true,
                                 nextRun: seconds(item["next_run_at"]),
                                 last: result(last?["state"] as? String, reason: last?["reason"] as? String),
                                 unread: item["unread_failures"] as? Int ?? 0,
                                 kind: body["type"] as? String == "command" ? .command : .prompt,
                                 folder: body["folder"] as? String,
                                 trigger: AnySendableJSON.object(item["trigger"]),
                                 timeoutSeconds: item["timeout_seconds"] as? Int)
        }
    }

    /// The runs of `cmux automation history --json`, newest first, by automation id. A failed
    /// run that finished after its automation's `seenAt` is unread.
    public static func runs(_ data: Data, seenAt: [String: Double] = [:]) -> [String: [Run]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["runs"] as? [[String: Any]] else { return [:] }
        var out: [String: [Run]] = [:]
        for item in items {
            guard let id = item["id"] as? String, let automation = item["automation"] as? String,
                  let at = seconds(item["started_at"]) ?? seconds(item["scheduled_at"]) ?? seconds(item["created_at"]) else { continue }
            let state = item["state"] as? String
            let reason = item["reason"] as? String
            let finished = (item["finished_at"] as? Double) ?? at.timeIntervalSince1970
            let result = result(state, reason: reason)
            let unread = (result == .failed || result == .needsYou) && finished > (seenAt[automation] ?? 0)
            out[automation, default: []].append(Run(
                id: id, at: at, result: result, reason: reason,
                lateSeconds: item["late_seconds"] as? Int ?? 0, session: item["session"] as? String,
                logPath: item["log_path"] as? String, trigger: item["trigger"] as? String,
                attempt: item["attempt"] as? Int ?? 0, unread: unread))
        }
        return out.mapValues { $0.sorted { $0.at > $1.at } }
    }

    /// When the person last looked at each automation (`seen_at` of `list --json`).
    public static func seenAt(_ data: Data) -> [String: Double] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["automations"] as? [[String: Any]] else { return [:] }
        var out: [String: Double] = [:]
        for item in items { if let id = item["id"] as? String { out[id] = item["seen_at"] as? Double ?? 0 } }
        return out
    }

    /// This Mac's runner as `list --json` says it: nil from a CLI before heartbeats.
    public static func runner(_ data: Data) -> RunnerHealth? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let health = (root["runner"] as? [String: Any])?["health"] as? String { return RunnerHealth(rawValue: health) }
        return (root["runner_running"] as? Bool).map { $0 ? .running : .stopped }
    }

    /// Rows from a Cloud `automation.list` value (times in milliseconds).
    public static func cloud(_ data: Data) -> [AutomationRow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["automations"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let body = item["body"] as? [String: Any] ?? [:]
            let specs = (item["triggers"] as? [[String: Any]] ?? []).map { $0["spec"] as? [String: Any] ?? $0 }
            let schedule = specs.first(where: { ($0["type"] as? String) != "manual" }).map { describe($0) } ?? describe(["type": "manual"])
            let next = (item["next_run_at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            // A `steps` body is a command on a Cloud machine (`--command … --target cloud`); its words are in the description.
            let command = (body["type"] as? String) == "steps"
            let task = command ? Self.cloudCommand(item["description"] as? String) : body["prompt"] as? String ?? ""
            return AutomationRow(id: id, name: name, target: .cloud, schedule: schedule, task: task,
                                 enabled: item["enabled"] as? Bool ?? true, nextRun: next, last: .none, kind: command ? .command : .chief,
                                 trigger: AnySendableJSON.object(specs.first(where: { ($0["type"] as? String) != "manual" })))
        }
    }

    /// The command of a Cloud command automation, from the description the CLI wrote.
    static func cloudCommand(_ description: String?) -> String {
        let prefix = "Cloud command made with cmux automation: "
        guard let description, description.hasPrefix(prefix) else { return description ?? "" }
        return String(description.dropFirst(prefix.count))
    }

    /// The runs of `cmux automation history --target cloud --json` (the Cloud's `run.list`), newest
    /// first, by automation id: times in milliseconds, a failure's reason its message (`step 3: exit 3:
    /// error: 2 tests failed`), else its code. `commands`: the Cloud command automations, whose runs
    /// have a log on their machine.
    public static func cloudRuns(_ data: Data, commands: Set<String> = []) -> [String: [Run]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["runs"] as? [[String: Any]] else { return [:] }
        let ms = { (value: Any?) in (value as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
        var out: [String: [Run]] = [:]
        for item in items {
            guard let id = item["id"] as? String, let automation = item["automation"] as? String,
                  let at = ms(item["started_at"]) ?? ms(item["created_at"]) else { continue }
            let error = item["error"] as? [String: Any]
            let result = result(item["state"] as? String, reason: error?["code"] as? String)
            let trigger = item["trigger"] as? [String: Any]
            let late = ms(trigger?["scheduled_at"]).map { max(0, Int(at.timeIntervalSince($0))) } ?? 0
            let started = item["started_at"] is Double
            out[automation, default: []].append(Run(
                id: id, at: at, result: result, reason: (error?["message"] as? String) ?? (error?["code"] as? String),
                lateSeconds: late > 60 ? late : 0, logPath: commands.contains(automation) && started ? "cloud" : nil,
                trigger: (trigger?["type"] as? String).map { $0 == "cron" ? "schedule" : $0 }))
        }
        return out.mapValues { $0.sorted { $0.at > $1.at } }
    }

    private static func seconds(_ value: Any?) -> Date? {
        (value as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    private static func result(_ state: String?, reason: String? = nil) -> LastResult {
        if state == "failed", reason == "needs_permission" { return .needsYou }
        return switch state {
        case "succeeded": .succeeded
        case "failed", "dead", "cancelled": .failed
        case "running", "queued", "sleeping", "waiting": .running
        case "skipped": .skipped
        default: .none
        }
    }

    private static func describe(_ trigger: [String: Any]?) -> String {
        guard let trigger else { return "" }
        switch trigger["type"] as? String {
        case "cron": return "cron \(trigger["expr"] as? String ?? "") (\(trigger["tz"] as? String ?? "local"))"
        case "every": return "every \(((trigger["seconds"] as? Int) ?? 0) / 60)m"
        case "webhook": return "webhook"
        case "at": return "once"
        default: return "manual"
        }
    }
}

/// Whether this Mac's runner starts anything (`cmux automation runner status`).
public enum RunnerHealth: String, Sendable {
    /// It runs and beats.
    case running
    /// It holds its lock but stopped beating: hung.
    case stalled
    /// Nothing runs: no schedule or event starts a run.
    case stopped
}

/// A JSON value that is `Sendable` and `Equatable`, for the parts of a CLI answer a row keeps.
public nonisolated enum AnySendableJSON: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([AnySendableJSON])
    case object([String: AnySendableJSON])

    init(_ value: Any?) {
        switch value {
        case let s as String: self = .string(s)
        case let n as NSNumber: self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map(AnySendableJSON.init))
        case let o as [String: Any]: self = .object(o.mapValues(AnySendableJSON.init))
        default: self = .null
        }
    }

    /// `value` as an object's members, empty when it is not an object.
    static func object(_ value: Any?) -> [String: AnySendableJSON] {
        if case let .object(members) = AnySendableJSON(value) { return members }
        return [:]
    }

    /// The string, or nil.
    public var string: String? { if case let .string(s) = self { return s }; return nil }
    /// The number, or nil.
    public var number: Double? { if case let .number(n) = self { return n }; return nil }
}
