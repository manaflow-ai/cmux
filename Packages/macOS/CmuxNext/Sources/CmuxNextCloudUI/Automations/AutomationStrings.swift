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
}
