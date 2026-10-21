import Foundation

/// The words of the Chief Settings cards (`HomeChiefSettingsCard`): each card's title, the line
/// under each Brain row that says what it changes, and the last turn's measures.
nonisolated enum HomeChiefCardStrings {
    static var identity: String { String(localized: "home.engine.card.identity", defaultValue: "Identity", table: "Home", bundle: .module) }
    static var brain: String { String(localized: "home.engine.card.brain", defaultValue: "Brain", table: "Home", bundle: .module) }
    static var memory: String { String(localized: "home.engine.card.memory", defaultValue: "Memory", table: "Home", bundle: .module) }
    /// The Brain card's first row: the agent the Chief's turns run on (an acpmux harness).
    static var backend: String { String(localized: "home.engine.card.backend", defaultValue: "Backend", table: "Home", bundle: .module) }

    static var backendHelp: String {
        String(localized: "home.engine.card.backendHelp", defaultValue: "The agent that runs each of the Chief's turns.", table: "Home", bundle: .module)
    }
    static var modelHelp: String {
        String(localized: "home.engine.card.modelHelp", defaultValue: "The model the Chief thinks with.", table: "Home", bundle: .module)
    }
    static var effortHelp: String {
        String(localized: "home.engine.card.effortHelp", defaultValue: "How long it thinks before it answers. Higher is slower and costs more.",
               table: "Home", bundle: .module)
    }
    static var speedHelp: String {
        String(localized: "home.engine.card.speedHelp", defaultValue: "Fast answers sooner, at a higher price.", table: "Home", bundle: .module)
    }
    static var memoryHelp: String {
        String(localized: "home.engine.card.memoryHelp", defaultValue: "What the Chief remembers between conversations. You can read, edit and delete it.",
               table: "Home", bundle: .module)
    }

    // MARK: Last turn

    static var noTurnHelp: String {
        String(localized: "home.engine.card.noTurnHelp", defaultValue: "Time, cost and cache use show here after the Chief answers.",
               table: "Home", bundle: .module)
    }
    static var time: String { String(localized: "home.engine.card.time", defaultValue: "Time", table: "Home", bundle: .module) }
    static var cost: String { String(localized: "home.engine.card.cost", defaultValue: "Cost", table: "Home", bundle: .module) }
    static var tokens: String { String(localized: "home.engine.card.tokens", defaultValue: "Tokens", table: "Home", bundle: .module) }
    static var cache: String { String(localized: "home.engine.card.cache", defaultValue: "Cached", table: "Home", bundle: .module) }
    static var tools: String { String(localized: "home.engine.card.tools", defaultValue: "Tools", table: "Home", bundle: .module) }
}
