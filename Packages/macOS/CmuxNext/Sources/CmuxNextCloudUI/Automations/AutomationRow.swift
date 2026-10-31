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

        public init(id: String, at: Date, result: LastResult, reason: String? = nil, lateSeconds: Int = 0) {
            self.id = id
            self.at = at
            self.result = result
            self.reason = reason
            self.lateSeconds = lateSeconds
        }
    }

    public var id: String
    public var name: String
    public var target: Target
    /// The schedule in words, from the CLI (`cron 0 9 * * 1-5 (local)`, `every 30m`, `manual only`).
    public var schedule: String
    /// The prompt or command a run does.
    public var task: String
    public var enabled: Bool
    public var nextRun: Date?
    public var last: LastResult
    public var runs: [Run]

    public init(id: String, name: String, target: Target, schedule: String, task: String, enabled: Bool,
                nextRun: Date?, last: LastResult, runs: [Run] = []) {
        self.id = id
        self.name = name
        self.target = target
        self.schedule = schedule
        self.task = task
        self.enabled = enabled
        self.nextRun = nextRun
        self.last = last
        self.runs = runs
    }

    /// A failed last run: the row goes to "Needs you".
    public var needsYou: Bool { enabled && last == .failed }

    /// Rows from `cmux automation list --json` (times in seconds).
    public static func local(_ data: Data) -> [AutomationRow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["automations"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let body = item["body"] as? [String: Any] ?? [:]
            let task = body["prompt"] as? String ?? body["command"] as? String ?? ""
            let last = item["last_run"] as? [String: Any]
            return AutomationRow(id: id, name: name, target: .thisMac, schedule: describe(item["trigger"] as? [String: Any]),
                                 task: task, enabled: item["enabled"] as? Bool ?? true,
                                 nextRun: seconds(item["next_run_at"]), last: result(last?["state"] as? String))
        }
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
            return AutomationRow(id: id, name: name, target: .cloud, schedule: schedule, task: body["prompt"] as? String ?? "",
                                 enabled: item["enabled"] as? Bool ?? true, nextRun: next, last: .none)
        }
    }

    private static func seconds(_ value: Any?) -> Date? {
        (value as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    private static func result(_ state: String?) -> LastResult {
        switch state {
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
