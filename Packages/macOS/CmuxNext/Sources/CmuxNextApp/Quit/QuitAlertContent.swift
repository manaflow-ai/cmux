/// What the quit dialog says (R96, R138: a cmux dialog, minimal and plain).
/// The first step keeps the terminals by default and hides the end choices
/// behind "Quit Everything…", which asks once more.
struct QuitAlertContent: Equatable {
    enum Button: String, Equatable {
        /// Keep Sessions Running (the default).
        case keep
        /// Quit, for the incognito-only question.
        case quit
        case cancel
        /// Opens the confirmation.
        case quitEverything = "quit-everything"
        /// End every local terminal, keep the layout.
        case confirmQuitEverything = "confirm-quit-everything"
        /// Also delete the workspaces.
        case endEverything = "end-everything"
    }

    var title: String
    /// One short sentence per line.
    var lines: [String]
    /// The first is the primary button; `QuitAlert` draws it last.
    var buttons: [Button]
    var showsSuppression: Bool

    var message: String { lines.joined(separator: "\n") }

    /// "Quit cmux?": how many terminals keep running, how many programs run,
    /// and one line each for incognito windows and other machines when
    /// relevant. With only incognito terminals (or a remembered end), it is
    /// the incognito close confirmation: Quit and Cancel.
    static func main(_ prompt: QuitPrompt) -> QuitAlertContent {
        guard prompt.offersSessionChoice else {
            var lines = [QuitStrings.incognitoOnly]
            if prompt.remoteSessions { lines.append(QuitStrings.remote) }
            return QuitAlertContent(title: ConfirmationStrings.quitIncognitoTitle, lines: lines, buttons: [.quit, .cancel],
                                    showsSuppression: false)
        }
        var lines = [QuitStrings.terminalsKeepRunning(prompt.terminals)]
        if prompt.runningPrograms > 0 { lines.append(QuitStrings.programsRunning(prompt.runningPrograms)) }
        if !prompt.incognitoPrograms.isEmpty { lines.append(QuitStrings.incognitoCloses) }
        if prompt.remoteSessions { lines.append(QuitStrings.remote) }
        return QuitAlertContent(title: QuitStrings.title, lines: lines, buttons: [.keep, .cancel, .quitEverything],
                                showsSuppression: true)
    }

    /// "End all terminals?", asked once after "Quit Everything…".
    static var endConfirmation: QuitAlertContent {
        QuitAlertContent(title: QuitStrings.endTitle, lines: [QuitStrings.endEverythingDeletes],
                         buttons: [.confirmQuitEverything, .cancel, .endEverything], showsSuppression: false)
    }

    /// The first step (Return and a second Cmd-Q keep), not the confirmation.
    var isFirstStep: Bool { buttons.first == .keep || buttons.first == .quit }

    static func title(of button: Button) -> String {
        switch button {
        case .keep: QuitStrings.keepSessionsRunning
        case .quit: ConfirmationStrings.quit
        case .cancel: ConfirmationStrings.cancel
        case .quitEverything: QuitStrings.quitEverythingEllipsis
        case .confirmQuitEverything: QuitStrings.quitEverything
        case .endEverything: QuitStrings.endEverything
        }
    }
}
