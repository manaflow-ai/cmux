public import Foundation

/// The user-facing text of the Automations page, in Resources/Cloud.xcstrings with every app locale.
public nonisolated struct AutomationStrings: Sendable {
    public init() {}

    public var title: String { String(localized: "automations.title", defaultValue: "Automations", table: "Cloud", bundle: .module) }
    public var new: String { String(localized: "automations.new", defaultValue: "New", table: "Cloud", bundle: .module) }
    public func active(_ count: Int) -> String {
        String(format: String(localized: "automations.activeCount", defaultValue: "%lld active", table: "Cloud", bundle: .module), count)
    }

    public func section(_ section: AutomationsPage.Section) -> String {
        switch section {
        case .needsYou: String(localized: "automations.section.needsYou", defaultValue: "Needs you", table: "Cloud", bundle: .module)
        case .today: String(localized: "automations.section.today", defaultValue: "Today", table: "Cloud", bundle: .module)
        case .later: String(localized: "automations.section.later", defaultValue: "Later", table: "Cloud", bundle: .module)
        case .paused: String(localized: "automations.section.paused", defaultValue: "Paused", table: "Cloud", bundle: .module)
        }
    }

    public func target(_ target: AutomationRow.Target) -> String {
        switch target {
        case .thisMac: String(localized: "automations.target.thisMac", defaultValue: "This Mac", table: "Cloud", bundle: .module)
        case .cloud: String(localized: "automations.target.cloud", defaultValue: "Cloud", table: "Cloud", bundle: .module)
        }
    }

    public var failed: String { String(localized: "automations.failed", defaultValue: "Failed", table: "Cloud", bundle: .module) }
    public var paused: String { String(localized: "automations.paused", defaultValue: "Paused", table: "Cloud", bundle: .module) }
    public var runNow: String { String(localized: "automations.runNow", defaultValue: "Run now", table: "Cloud", bundle: .module) }
    public var pause: String { String(localized: "automations.pause", defaultValue: "Pause", table: "Cloud", bundle: .module) }
    public var resume: String { String(localized: "automations.resume", defaultValue: "Resume", table: "Cloud", bundle: .module) }
    public var edit: String { String(localized: "automations.edit", defaultValue: "Edit", table: "Cloud", bundle: .module) }
    public var history: String { String(localized: "automations.history", defaultValue: "History", table: "Cloud", bundle: .module) }
    public var noRuns: String { String(localized: "automations.noRuns", defaultValue: "No runs yet.", table: "Cloud", bundle: .module) }
    public var empty: String {
        String(localized: "automations.empty",
               defaultValue: "No automations yet. Ask your Chief (\"every weekday at 9, summarize my PRs\") or press New.",
               table: "Cloud", bundle: .module)
    }
    public func next(_ when: String) -> String {
        String(format: String(localized: "automations.next", defaultValue: "next %@", table: "Cloud", bundle: .module), when)
    }
    public func late(_ minutes: Int) -> String {
        String(format: String(localized: "automations.late", defaultValue: "ran %lld min late", table: "Cloud", bundle: .module), minutes)
    }

    /// Why `target`'s automations did not load, from the source's error `code`.
    public func problem(_ target: AutomationRow.Target, code: String) -> String {
        switch (target, code) {
        case (.cloud, "automation.signed_out"):
            String(localized: "automations.problem.signedOut", defaultValue: "Sign in to cmux to see your Cloud automations.", table: "Cloud", bundle: .module)
        case (.cloud, "feature.disabled"):
            String(localized: "automations.problem.cloudOff", defaultValue: "Your administrator turned off cmux Cloud, so Cloud automations are not shown.", table: "Cloud", bundle: .module)
        case (.cloud, _):
            String(localized: "automations.problem.cloud", defaultValue: "Could not reach cmux Cloud; Cloud automations are not shown.", table: "Cloud", bundle: .module)
        case (.thisMac, _):
            String(localized: "automations.problem.thisMac", defaultValue: "Could not read this Mac's automations (cmux automation list failed).", table: "Cloud", bundle: .module)
        }
    }

    // MARK: Runner, buttons, runs and the form (docs/automations-desktop-parity.md)

    public var runnerStopped: String { String(localized: "automations.runner.stopped", defaultValue: "Automations on this Mac are off: no schedule or event starts them.", table: "Cloud", bundle: .module) }
    public var runnerStalled: String { String(localized: "automations.runner.stalled", defaultValue: "The automations runner on this Mac stopped responding.", table: "Cloud", bundle: .module) }
    public var runnerTurnOn: String { String(localized: "automations.runner.turnOn", defaultValue: "Turn On", table: "Cloud", bundle: .module) }
    public var runnerRestart: String { String(localized: "automations.runner.restart", defaultValue: "Restart", table: "Cloud", bundle: .module) }
    public var delete: String { String(localized: "automations.delete", defaultValue: "Delete", table: "Cloud", bundle: .module) }
    public var deleteConfirm: String { String(localized: "automations.deleteConfirm", defaultValue: "Delete this automation? Its run history stays on this Mac.", table: "Cloud", bundle: .module) }
    public var cancel: String { String(localized: "automations.cancel", defaultValue: "Cancel", table: "Cloud", bundle: .module) }
    public var openChat: String { String(localized: "automations.openChat", defaultValue: "Open chat", table: "Cloud", bundle: .module) }
    public var log: String { String(localized: "automations.log", defaultValue: "Log", table: "Cloud", bundle: .module) }
    public var hideLog: String { String(localized: "automations.hideLog", defaultValue: "Hide log", table: "Cloud", bundle: .module) }
    public var emptyLog: String { String(localized: "automations.emptyLog", defaultValue: "This run wrote nothing.", table: "Cloud", bundle: .module) }
    public var formNewTitle: String { String(localized: "automations.form.newTitle", defaultValue: "New automation", table: "Cloud", bundle: .module) }
    public var formEditTitle: String { String(localized: "automations.form.editTitle", defaultValue: "Edit automation", table: "Cloud", bundle: .module) }
    public var formName: String { String(localized: "automations.form.name", defaultValue: "Name", table: "Cloud", bundle: .module) }
    public var formWhatToDo: String { String(localized: "automations.form.whatToDo", defaultValue: "What it does", table: "Cloud", bundle: .module) }
    public var formPrompt: String { String(localized: "automations.form.prompt", defaultValue: "Agent prompt", table: "Cloud", bundle: .module) }
    public var formCommand: String { String(localized: "automations.form.command", defaultValue: "Shell command", table: "Cloud", bundle: .module) }
    public var formWhen: String { String(localized: "automations.form.when", defaultValue: "When", table: "Cloud", bundle: .module) }
    public var formWhere: String { String(localized: "automations.form.where", defaultValue: "Runs on", table: "Cloud", bundle: .module) }
    public var formFolder: String { String(localized: "automations.form.folder", defaultValue: "Folder", table: "Cloud", bundle: .module) }
    public var formFolderPlaceholder: String { String(localized: "automations.form.folderPlaceholder", defaultValue: "Optional, for example ~/code/app", table: "Cloud", bundle: .module) }
    public var formTimeout: String { String(localized: "automations.form.timeout", defaultValue: "Time limit (minutes)", table: "Cloud", bundle: .module) }
    public var formSaving: String { String(localized: "automations.form.saving", defaultValue: "Saving…", table: "Cloud", bundle: .module) }
    public var formCreate: String { String(localized: "automations.form.create", defaultValue: "Create", table: "Cloud", bundle: .module) }
    public var formSave: String { String(localized: "automations.form.save", defaultValue: "Save", table: "Cloud", bundle: .module) }
    public var cronHelp: String { String(localized: "automations.form.cronHelp", defaultValue: "minute hour day month weekday, in this Mac's time zone", table: "Cloud", bundle: .module) }
    public var problemName: String { String(localized: "automations.problem.name", defaultValue: "Give it a name.", table: "Cloud", bundle: .module) }
    public var problemTask: String { String(localized: "automations.problem.task", defaultValue: "Say what it does.", table: "Cloud", bundle: .module) }
    public var problemInterval: String { String(localized: "automations.problem.interval", defaultValue: "At least 1 minute.", table: "Cloud", bundle: .module) }
    public var problemCron: String { String(localized: "automations.problem.cron", defaultValue: "Enter a cron schedule.", table: "Cloud", bundle: .module) }
    public var scheduleUnchanged: String { String(localized: "automations.schedule.unchanged", defaultValue: "As it is", table: "Cloud", bundle: .module) }

    public func retry(_ attempt: Int) -> String {
        String(format: String(localized: "automations.retry", defaultValue: "retry %lld", table: "Cloud", bundle: .module), attempt)
    }
    public func everyMinutes(_ minutes: Int) -> String {
        String(format: String(localized: "automations.everyMinutes", defaultValue: "every %lld min", table: "Cloud", bundle: .module), minutes)
    }

    public func scheduleKind(_ kind: AutomationDraft.Schedule.Kind) -> String {
        switch kind {
        case .manual: String(localized: "automations.schedule.manual", defaultValue: "Only when I run it", table: "Cloud", bundle: .module)
        case .every: String(localized: "automations.schedule.every", defaultValue: "Every few minutes", table: "Cloud", bundle: .module)
        case .hourly: String(localized: "automations.schedule.hourly", defaultValue: "Hourly", table: "Cloud", bundle: .module)
        case .daily: String(localized: "automations.schedule.daily", defaultValue: "Daily", table: "Cloud", bundle: .module)
        case .weekdays: String(localized: "automations.schedule.weekdays", defaultValue: "Weekdays", table: "Cloud", bundle: .module)
        case .weekly: String(localized: "automations.schedule.weekly", defaultValue: "Weekly", table: "Cloud", bundle: .module)
        case .cron: String(localized: "automations.schedule.cron", defaultValue: "Custom (cron)", table: "Cloud", bundle: .module)
        }
    }

    /// A run's reason (`exit_7`, `machine_asleep`, `needs_permission`) in words; an unknown one as it is.
    public func reason(_ reason: String) -> String {
        if let code = reason.wholeMatch(of: #/exit_(-?\d+)/#)?.1 {
            return String(format: String(localized: "automations.reason.exit", defaultValue: "Exited with code %@", table: "Cloud", bundle: .module), String(code))
        }
        if let signal = reason.wholeMatch(of: #/signal_(\d+)/#)?.1 {
            return String(format: String(localized: "automations.reason.signal", defaultValue: "Stopped by signal %@", table: "Cloud", bundle: .module), String(signal))
        }
        if reason.hasPrefix("start_failed") || reason.hasPrefix("error:") {
            return String(localized: "automations.reason.startFailed", defaultValue: "Could not start", table: "Cloud", bundle: .module)
        }
        if reason.hasPrefix("condition_") && reason != "condition_false" {
            return String(localized: "automations.reason.conditionFailed", defaultValue: "Its condition failed", table: "Cloud", bundle: .module)
        }
        switch reason {
        case "timeout": return String(localized: "automations.reason.timeout", defaultValue: "Ran past its time limit", table: "Cloud", bundle: .module)
        case "needs_permission": return String(localized: "automations.reason.needsPermission", defaultValue: "Stopped to ask for your approval", table: "Cloud", bundle: .module)
        case "runner_died": return String(localized: "automations.reason.runnerDied", defaultValue: "Stopped when the runner stopped", table: "Cloud", bundle: .module)
        case "superseded": return String(localized: "automations.reason.superseded", defaultValue: "Skipped: a later run covered it", table: "Cloud", bundle: .module)
        case "machine_asleep": return String(localized: "automations.reason.asleep", defaultValue: "Skipped: this Mac was asleep", table: "Cloud", bundle: .module)
        case "stale": return String(localized: "automations.reason.stale", defaultValue: "Skipped: too late to be useful", table: "Cloud", bundle: .module)
        case "previous_run_running": return String(localized: "automations.reason.overlap", defaultValue: "Skipped: the previous run was still going", table: "Cloud", bundle: .module)
        case "cooldown": return String(localized: "automations.reason.cooldown", defaultValue: "Skipped: cooling down", table: "Cloud", bundle: .module)
        case "cap_reached": return String(localized: "automations.reason.cap", defaultValue: "Skipped: daily limit reached", table: "Cloud", bundle: .module)
        case "condition_false": return String(localized: "automations.reason.conditionFalse", defaultValue: "Skipped: its condition said no", table: "Cloud", bundle: .module)
        default: return reason
        }
    }
}
