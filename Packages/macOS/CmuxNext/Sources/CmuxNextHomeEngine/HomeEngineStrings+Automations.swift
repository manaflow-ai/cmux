import Foundation

/// The Chief Settings card's Automations block (issue 25573).
nonisolated extension HomeEngineStrings {
    static var automationsSection: String {
        String(localized: "home.engine.automations", defaultValue: "Automations", table: "Home", bundle: .module)
    }
    /// The block with no automation yet: how to make one.
    static var automationsEmpty: String {
        String(localized: "home.engine.automations.empty",
               defaultValue: "None yet. Ask the Chief, for example: “Every morning at 9, summarize my open PRs.”",
               table: "Home", bundle: .module)
    }
    /// A schedule's trigger, by its cron ("0 9 * * *").
    static var automationScheduleFormat: String {
        String(localized: "home.engine.automations.schedule", defaultValue: "Schedule: %@", table: "Home", bundle: .module)
    }
    static var automationAgentDone: String {
        String(localized: "home.engine.automations.agentDone", defaultValue: "When a subagent finishes", table: "Home", bundle: .module)
    }
    /// An agent-done trigger limited to subagents whose title has a word.
    static var automationAgentDoneMatchingFormat: String {
        String(localized: "home.engine.automations.agentDoneMatching", defaultValue: "When a subagent titled “%@” finishes",
               table: "Home", bundle: .module)
    }
    /// A schedule's next run, by its date and time.
    static var automationNextFormat: String {
        String(localized: "home.engine.automations.next", defaultValue: "Next: %@", table: "Home", bundle: .module)
    }
    static var automationPaused: String {
        String(localized: "home.engine.automations.paused", defaultValue: "Paused", table: "Home", bundle: .module)
    }
    static var automationPause: String {
        String(localized: "home.engine.automations.pause", defaultValue: "Pause", table: "Home", bundle: .module)
    }
    static var automationResume: String {
        String(localized: "home.engine.automations.resume", defaultValue: "Resume", table: "Home", bundle: .module)
    }
    static var automationDelete: String {
        String(localized: "home.engine.automations.delete", defaultValue: "Delete", table: "Home", bundle: .module)
    }
}
