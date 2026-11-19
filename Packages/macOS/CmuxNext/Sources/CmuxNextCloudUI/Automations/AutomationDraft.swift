public import Foundation

/// The New and Edit form of the Automations page (docs/automations-desktop-parity.md): the few
/// fields a person fills, turned into the `cmux automation create` or `edit` words the CLI, the
/// Chief and MCP use too, so the form makes nothing they could not.
public nonisolated struct AutomationDraft: Equatable, Sendable {
    /// When it runs.
    public enum Schedule: Equatable, Sendable {
        case manual
        case every(minutes: Int)
        case hourly
        case daily(hour: Int, minute: Int)
        case weekdays(hour: Int, minute: Int)
        /// `weekday` 0 is Sunday.
        case weekly(weekday: Int, hour: Int, minute: Int)
        case cron(String)
        /// An edit that leaves the schedule as it is (a watch or an event trigger the form cannot show).
        case unchanged

        /// The picker's choices, in order.
        public enum Kind: String, CaseIterable, Sendable {
            case manual, every, hourly, daily, weekdays, weekly, cron
        }

        public var kind: Kind? {
            switch self {
            case .manual: .manual
            case .every: .every
            case .hourly: .hourly
            case .daily: .daily
            case .weekdays: .weekdays
            case .weekly: .weekly
            case .cron: .cron
            case .unchanged: nil
            }
        }
    }

    /// Why the form cannot save, per field.
    public enum Problem: Equatable, Sendable {
        case nameMissing, taskMissing, intervalTooShort, cronMissing
    }

    public var name: String
    /// Prompt (an agent chat each run) or command (a shell command each run).
    public var isCommand: Bool
    public var task: String
    /// Empty: no folder.
    public var folder: String
    public var schedule: Schedule
    public var timeoutMinutes: Int
    /// Runs on cmux Cloud instead of on this Mac: a prompt in the Cloud Chief, a command on a Cloud machine.
    public var cloud: Bool
    /// The automation being edited; nil for a new one.
    public let editing: String?

    /// A new automation: a prompt, every weekday at 9:00, on this Mac.
    public init(name: String = "", isCommand: Bool = false, task: String = "", folder: String = "",
                schedule: Schedule = .weekdays(hour: 9, minute: 0), timeoutMinutes: Int = 30, cloud: Bool = false,
                editing: String? = nil) {
        self.name = name
        self.isCommand = isCommand
        self.task = task
        self.folder = folder
        self.schedule = schedule
        self.timeoutMinutes = timeoutMinutes
        self.cloud = cloud
        self.editing = editing
    }

    /// The form for editing `row`, its fields filled from it.
    public init(editing row: AutomationRow) {
        self.init(name: row.name, isCommand: row.kind == .command, task: row.task, folder: row.folder ?? "",
                  schedule: Self.schedule(of: row.trigger), timeoutMinutes: max(1, (row.timeoutSeconds ?? 1800) / 60),
                  cloud: row.target == .cloud, editing: row.id)
    }

    /// What stops a save, in field order; empty when it can save.
    public var problems: [Problem] {
        var out: [Problem] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.nameMissing) }
        if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.taskMissing) }
        if case let .every(minutes) = schedule, minutes < 1 { out.append(.intervalTooShort) }
        if case let .cron(expr) = schedule, expr.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.cronMissing) }
        return out
    }

    /// The CLI words (after `cmux --json`): `automation create NAME …` or `automation edit ID …`.
    public var arguments: [String] {
        var words = ["automation"]
        if let editing {
            words += ["edit", editing, "--name", name.trimmingCharacters(in: .whitespacesAndNewlines)]
        } else {
            words += ["create", name.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        words += [isCommand ? "--command" : "--prompt", task]
        // A Cloud prompt runs in the Cloud Chief's chat; a Cloud command runs in a folder of its Cloud machine.
        let runsInAFolder = !cloud || isCommand
        if !folder.trimmingCharacters(in: .whitespaces).isEmpty, runsInAFolder { words += ["--folder", folder] }
        words += Self.words(schedule)
        if runsInAFolder { words += ["--timeout", "\(max(1, timeoutMinutes))m"] }
        if cloud { words += ["--target", "cloud"] }
        return words
    }

    static func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }

    static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    static func words(_ schedule: Schedule) -> [String] {
        switch schedule {
        case .manual: ["--manual"]
        case let .every(minutes): ["--every", "\(minutes)m"]
        case .hourly: ["--hourly"]
        case let .daily(h, m): ["--daily", clock(h, m)]
        case let .weekdays(h, m): ["--weekdays", clock(h, m)]
        case let .weekly(day, h, m): ["--weekly", "\(weekdayNames[((day % 7) + 7) % 7]) \(clock(h, m))"]
        case let .cron(expr): ["--cron", expr.trimmingCharacters(in: .whitespaces)]
        case .unchanged: []
        }
    }

    /// The form's schedule for a stored trigger: the presets come back as presets (they are stored
    /// as cron), any other cron as Custom, a watch or event trigger as unchanged.
    public static func schedule(of trigger: [String: AnySendableJSON]) -> Schedule {
        switch trigger["type"]?.string {
        case "manual": return .manual
        case "every": return .every(minutes: max(1, Int(trigger["seconds"]?.number ?? 60) / 60))
        case "cron":
            let expr = trigger["expr"]?.string ?? ""
            let f = expr.split(separator: " ").map(String.init)
            guard f.count == 5, let m = Int(f[0]) else { return .cron(expr) }
            if f[1] == "*", f[2] == "*", f[3] == "*", f[4] == "*" { return m == 0 ? .hourly : .cron(expr) }
            guard let h = Int(f[1]), f[2] == "*", f[3] == "*" else { return .cron(expr) }
            if f[4] == "*" { return .daily(hour: h, minute: m) }
            if f[4] == "1-5" { return .weekdays(hour: h, minute: m) }
            if let d = Int(f[4]), (0...7).contains(d) { return .weekly(weekday: d % 7, hour: h, minute: m) }
            return .cron(expr)
        default: return .unchanged
        }
    }
}
