/// What the quit dialog says (R96, R138: a cmux dialog, minimal and plain).
/// One step (#17501): Keep Sessions Running is the default and Quit
/// Everything sits beside it, so a quit never opens a second dialog. End
/// Everything (also delete the workspaces) is the File menu's.
struct QuitAlertContent: Equatable {
    enum Button: String, Equatable {
        /// Keep Sessions Running (the default).
        case keep
        /// Quit, for the incognito-only question.
        case quit
        case cancel
        /// End every local terminal, keep the layout.
        case confirmQuitEverything = "confirm-quit-everything"
        /// Also delete the workspaces (no button; `debug.quit` presses it).
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
        var lines: [String] = []
        if prompt.runningPrograms > 0 {
            lines += [QuitStrings.terminalsKeepRunning(prompt.terminals), QuitStrings.programsRunning(prompt.runningPrograms)]
        }
        // Agents are not warned about: they keep working in acpmux and reattach.
        if prompt.agentsInTurn > 0 { lines.append(QuitStrings.agentsKeepWorking(prompt.agentsInTurn)) }
        if !prompt.incognitoPrograms.isEmpty { lines.append(QuitStrings.incognitoCloses) }
        if prompt.remoteSessions { lines.append(QuitStrings.remote) }
        return QuitAlertContent(title: QuitStrings.title, lines: lines, buttons: [.keep, .cancel, .confirmQuitEverything],
                                showsSuppression: true)
    }

    static func title(of button: Button) -> String {
        switch button {
        case .keep: QuitStrings.keepSessionsRunning
        case .quit: ConfirmationStrings.quit
        case .cancel: ConfirmationStrings.cancel
        case .confirmQuitEverything: QuitStrings.quitEverything
        case .endEverything: QuitStrings.endEverything
        }
    }
}
