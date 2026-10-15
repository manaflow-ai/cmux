import Foundation

/// What a first-run row asks the app to do (``ChiefService/onFirstRunAction``).
enum ChiefFirstRunAction: Equatable {
    /// A new terminal tab.
    case openTerminal
    /// A new coding agent.
    case startAgent
}

/// One starter row of the empty Chief conversation: a concrete request,
/// with a glyph. A complete request sends at once; one the user finishes
/// (it ends with an ellipsis or names "these issues") only fills the box.
struct ChiefStarterPrompt: Equatable {
    /// The row's label.
    var title: String
    /// What goes in the message box.
    var text: String
    /// The SF Symbol drawn before the label.
    var symbol: String
    /// Sends at once (true) or waits in the box for the user to finish.
    var sends: Bool

    /// The starter rows, in order: the things Chief does best in cmux.
    static var all: [ChiefStarterPrompt] {
        [
            ChiefStarterPrompt(title: ChiefStrings.firstRunCloudMachine, text: ChiefStrings.firstRunCloudMachine,
                               symbol: "cloud", sends: true),
            ChiefStarterPrompt(title: ChiefStrings.firstRunCodexAgents, text: ChiefStrings.firstRunCodexAgents + ": ",
                               symbol: "person.3", sends: false),
            ChiefStarterPrompt(title: ChiefStrings.firstRunFontSize, text: ChiefStrings.firstRunFontSize,
                               symbol: "textformat.size", sends: true),
            ChiefStarterPrompt(title: ChiefStrings.firstRunAgentStatus, text: ChiefStrings.firstRunAgentStatus,
                               symbol: "list.bullet.rectangle", sends: true),
            ChiefStarterPrompt(title: ChiefStrings.firstRunRemember, text: fillText(ChiefStrings.firstRunRemember),
                               symbol: "brain", sends: false),
        ]
    }

    /// "Remember that I prefer…" becomes "Remember that I prefer " to finish.
    static func fillText(_ title: String) -> String {
        var text = title
        while let last = text.last, last == "…" || last == "." { text.removeLast() }
        return text + " "
    }
}
