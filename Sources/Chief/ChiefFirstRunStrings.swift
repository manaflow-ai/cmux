import Foundation

/// The first-run panel's strings beyond the row titles in ``ChiefStrings``
/// (`Resources/Localizable.xcstrings`).
extension ChiefStrings {
    /// The intro's first line: what Chief is.
    static var firstRunIntroTitle: String {
        String(localized: "chief.firstRun.intro.title", defaultValue: "Chief runs your coding agents and terminals.")
    }
    /// The intro's sentence under the title: what Chief does.
    static var firstRunIntroBody: String {
        String(localized: "chief.firstRun.intro.body",
               defaultValue: "It starts coding agents and checks on them, works in your terminals, and sets up Cloud machines with a desktop it can use for you.")
    }
    /// Over the agent rows.
    static var firstRunAgentsHeader: String {
        String(localized: "chief.firstRun.agentsHeader", defaultValue: "Your agents")
    }
    /// Over the workspace rows when no workspace has an agent.
    static var firstRunWorkspacesHeader: String {
        String(localized: "chief.firstRun.workspacesHeader", defaultValue: "Your workspaces")
    }
    /// An agent row's trailing status word.
    static func firstRunAgentStatus(_ status: ChiefAgentGlance.Status) -> String {
        switch status {
        case .needsYou: String(localized: "chief.firstRun.status.needsYou", defaultValue: "Needs you")
        case .done: String(localized: "chief.firstRun.status.done", defaultValue: "Done")
        case .working: String(localized: "chief.firstRun.status.working", defaultValue: "Working")
        case .idle: String(localized: "chief.firstRun.status.idle", defaultValue: "Idle")
        }
    }
    /// The keyboard hint under the rows; `keys` is the configured workspace
    /// shortcut, e.g. "⌃1…9".
    static func firstRunWorkspacesHint(_ keys: String) -> String {
        String(format: String(localized: "chief.firstRun.workspacesHint", defaultValue: "%@ switches workspaces."), keys)
    }
    /// VoiceOver label of the suggestion chips above the message box.
    static var firstRunSuggestions: String {
        String(localized: "chief.firstRun.suggestions", defaultValue: "Suggestions")
    }
}
