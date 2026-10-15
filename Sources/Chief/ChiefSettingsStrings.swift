import CmuxChief
import Foundation

/// The Chief Settings panel's strings beyond ``ChiefStrings``' original set
/// (`Resources/Localizable.xcstrings`): the Name field, section titles, the
/// "Default (Opus 5.5)" items, effort descriptions, the last turn's stats,
/// where the brain runs, and the header's brain hint. Wording follows
/// cmux-next `HomeEngineStrings` (feat-cmux-next
/// `Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/HomeEngineStrings.swift`).
enum ChiefSettingsStrings {
    // MARK: Sections

    static var sectionProfile: String { String(localized: "chief.settings.section.profile", defaultValue: "Profile") }
    static var sectionBrain: String { String(localized: "chief.settings.section.brain", defaultValue: "Brain") }
    static var sectionActivity: String { String(localized: "chief.settings.section.activity", defaultValue: "Activity") }

    // MARK: Name

    static var name: String { String(localized: "chief.settings.name", defaultValue: "Name") }
    static var nameHelp: String {
        String(localized: "chief.settings.name.help",
               defaultValue: "Shown in the header, the conversation list and the sidebar.")
    }

    // MARK: Pickers

    /// "Default (Opus 5.5)": the picker's first item names what the default resolves to.
    static func defaultItem(_ resolved: String) -> String {
        String(format: String(localized: "chief.settings.defaultFormat", defaultValue: "Default (%@)"), resolved)
    }

    /// One line under the Effort popup: what the level trades (cf. Claude's
    /// effort menu, "Higher effort means more thorough responses, but takes
    /// longer and uses your limits faster").
    static func effortDescription(_ id: String) -> String {
        switch id {
        case "low":
            return String(localized: "chief.settings.effort.description.low",
                          defaultValue: "Fastest replies at the lowest cost, with little reasoning.")
        case "medium":
            return String(localized: "chief.settings.effort.description.medium",
                          defaultValue: "Balanced speed and cost for everyday requests.")
        case "high":
            return String(localized: "chief.settings.effort.description.high",
                          defaultValue: "More thorough reasoning. Slower, and costs more.")
        case "xhigh":
            return String(localized: "chief.settings.effort.description.xhigh",
                          defaultValue: "Deep reasoning for hard problems. Noticeably slower.")
        case "max":
            return String(localized: "chief.settings.effort.description.max",
                          defaultValue: "The most reasoning. Slowest, and uses your limits fastest.")
        default:
            return String(localized: "chief.settings.effort.description.default",
                          defaultValue: "The model’s own level. Higher effort is more thorough, but slower and costs more.")
        }
    }

    // MARK: Last turn

    static var noTurn: String {
        String(localized: "chief.settings.lastTurn.none", defaultValue: "No turn yet in this session.")
    }

    /// "Last turn: claude · Opus 5.5 · 3.1 s · 2 tool calls · 64% cached".
    static func lastTurn(_ stats: ChiefTurnStats) -> String {
        var parts: [String] = []
        if let engine = stats.engine {
            parts.append(engine.harness)
            parts.append(modelName(engine.model, harness: engine.harness))
        }
        let seconds = stats.duration.formatted(.number.precision(.fractionLength(1)))
        parts.append(String(format: String(localized: "chief.settings.lastTurn.seconds", defaultValue: "%@ s"), seconds))
        let tools = Int64(stats.toolCalls)
        parts.append(String(localized: "chief.settings.lastTurn.toolCalls", defaultValue: "\(tools) tool calls"))
        if let rate = stats.cacheHitRate {
            let percent = rate.formatted(.percent.precision(.fractionLength(0)))
            parts.append(String(format: String(localized: "chief.settings.lastTurn.cached", defaultValue: "%@ cached"), percent))
        }
        if stats.stopped {
            parts.append(String(localized: "chief.settings.lastTurn.stopped", defaultValue: "stopped"))
        } else if stats.failed {
            parts.append(String(localized: "chief.settings.lastTurn.failed", defaultValue: "failed"))
        }
        return String(format: String(localized: "chief.settings.lastTurn", defaultValue: "Last turn: %@"),
                      parts.joined(separator: " · "))
    }

    // MARK: Where it runs

    /// "Runs on this Mac (~/.cmux/chief/com.cmuxterm.app)."
    static func runsOnThisMac(_ path: String) -> String {
        String(format: String(localized: "chief.settings.runsOnThisMac", defaultValue: "Runs on this Mac (%@)."), path)
    }
    static var showTranscriptLog: String {
        String(localized: "chief.settings.showTranscriptLog", defaultValue: "Show Transcript Log")
    }
    /// The button's tooltip, with the CLI line that reports the same state.
    static var showTranscriptLogHelp: String {
        String(localized: "chief.settings.showTranscriptLog.help",
               defaultValue: "Reveals this conversation’s log (JSON Lines) in Finder. From a terminal: cmux chief status")
    }

    // MARK: Brain hint

    /// The header pill's tooltip: "Answers with Opus 5.5 · Medium. Click for Chief Settings."
    static func pillToolTip(_ hint: String) -> String {
        String(format: String(localized: "chief.settings.pillToolTip",
                              defaultValue: "Answers with %@. Click for Chief Settings."), hint)
    }

    /// The quiet brain hint under the header pill: "Opus 5.5 · Medium"; the
    /// effort is left out while it is the model's default.
    static func brainHint(_ settings: ChiefEngineSettings) -> String {
        let model = modelName(settings.resolvedModel, harness: settings.resolvedHarness.rawValue)
        guard !settings.effort.isEmpty else { return model }
        return model + " · " + ChiefStrings.effortName(settings.effort)
    }

    /// A model's short name: the catalog's display name without the vendor
    /// prefix ("Opus 5.5", "GPT-6.1 Sol"); an unlisted id as is.
    static func modelName(_ id: String, harness: String) -> String {
        let resolved = CmuxChief.ChiefHarness(rawValue: harness) ?? .claude
        guard let option = ChiefModelCatalog.model(id, for: resolved) else { return id }
        let prefix = "Claude "
        return option.displayName.hasPrefix(prefix) ? String(option.displayName.dropFirst(prefix.count)) : option.displayName
    }
}
