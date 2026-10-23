import Foundation

/// What a first-run row asks the app to do (``ChiefService/onFirstRunAction``).
enum ChiefFirstRunAction: Equatable {
    /// A new terminal tab.
    case openTerminal
    /// A new coding agent.
    case startAgent
}

/// One suggestion chip of the empty Chief conversation, just above the
/// message box like Messages' suggested replies: a concrete request with a
/// glyph. A complete question sends at once; a request the user finishes
/// (set-up details, a preference) only fills the box, cursor ready.
struct ChiefStarterPrompt: Equatable {
    /// The chip's label.
    var title: String
    /// What goes in the message box.
    var text: String
    /// The SF Symbol before the label (13 pt regular, like every first-run glyph).
    var symbol: String
    /// Sends at once (true) or waits in the box for the user to finish.
    var sends: Bool

    /// The chips, in order. Three, so they stay one or two short lines in a
    /// 360 pt pane.
    static var all: [ChiefStarterPrompt] {
        [
            ChiefStarterPrompt(title: ChiefStrings.firstRunAgentStatus, text: ChiefStrings.firstRunAgentStatus,
                               symbol: "square.stack.3d.up", sends: true),
            ChiefStarterPrompt(title: ChiefStrings.firstRunCloudMachine, text: ChiefStrings.firstRunCloudMachine + " ",
                               symbol: "cloud", sends: false),
            ChiefStarterPrompt(title: ChiefStrings.firstRunRemember, text: fillText(ChiefStrings.firstRunRememberFill),
                               symbol: "bookmark", sends: false),
        ]
    }

    /// "Remember that I prefer" (or a translation ending in "…") becomes
    /// "Remember that I prefer " to finish, the cursor after the space.
    static func fillText(_ title: String) -> String {
        var text = title
        while let last = text.last, last == "…" || last == "." || last == "。" { text.removeLast() }
        while let last = text.last, last == " " { text.removeLast() }
        return text + " "
    }
}
