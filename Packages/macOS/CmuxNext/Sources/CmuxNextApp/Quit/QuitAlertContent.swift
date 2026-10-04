/// What the quit alerts say (user feedback 2026-09-30: minimal, plain,
/// native). The first alert keeps the terminals by default and hides the
/// end choices behind "End Sessions…", which asks once more.
struct QuitAlertContent: Equatable {
    enum Button: String, Equatable {
        case quit
        case cancel
        /// Opens the end confirmation.
        case endSessions = "end"
        case endKeepLayout = "end-keep-layout"
        case endEverything = "end-everything"
    }

    var title: String
    /// One short sentence per line.
    var lines: [String]
    /// The first is the default (Return); `QuitAlert` draws Cancel first.
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
        return QuitAlertContent(title: QuitStrings.title, lines: lines, buttons: [.quit, .cancel, .endSessions], showsSuppression: true)
    }

    /// "End all terminals?", asked once after "End Sessions…".
    static var endConfirmation: QuitAlertContent {
        QuitAlertContent(title: QuitStrings.endTitle, lines: [QuitStrings.endEverythingDeletes],
                         buttons: [.endKeepLayout, .cancel, .endEverything], showsSuppression: false)
    }

    static func title(of button: Button) -> String {
        switch button {
        case .quit: ConfirmationStrings.quit
        case .cancel: ConfirmationStrings.cancel
        case .endSessions: QuitStrings.endSessions
        case .endKeepLayout: QuitStrings.endKeepLayout
        case .endEverything: QuitStrings.endEverything
        }
    }
}
