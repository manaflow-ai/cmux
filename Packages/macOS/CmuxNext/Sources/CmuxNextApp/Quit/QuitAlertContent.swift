/// What the quit dialog says (R96, R138: a cmux dialog, minimal and plain).
/// One step (#17501): Keep Sessions Running is the default (Return), and End
/// Sessions (Keep Layout), End Everything (also delete the workspaces) and
/// Cancel sit beside it, so a quit never opens a second dialog (QUIT P0).
struct QuitAlertContent: Equatable {
    enum Button: String, Equatable {
        /// Keep Sessions Running (the default).
        case keep
        /// Quit, for the incognito-only question.
        case quit
        case cancel
        /// End every local terminal, keep the layout.
        case endKeepLayout = "end-keep-layout"
        /// End every local terminal and delete the local workspaces (its own
        /// button in the session choice, and when a remembered End Everything
        /// asks: `QuitPrompt.confirmsEndEverything`).
        case endEverything = "end-everything"
    }

    var title: String
    /// One short sentence per line.
    var lines: [String]
    /// The first is the primary button; `QuitAlert` draws it last.
    var buttons: [Button]
    var showsSuppression: Bool

    var message: String { lines.joined(separator: "\n") }

    /// "Quit cmux?": how many programs run, how many agents are working, and
    /// one line for incognito windows when relevant. With only incognito
    /// terminals (or a remembered end), it is the incognito close
    /// confirmation: Quit and Cancel.
    static func main(_ prompt: QuitPrompt) -> QuitAlertContent {
        if prompt.confirmsEndEverything {
            var lines = [QuitStrings.endEverythingLine]
            if !prompt.incognitoPrograms.isEmpty { lines.append(QuitStrings.incognitoCloses) }
            return QuitAlertContent(title: QuitStrings.endEverythingTitle, lines: lines,
                                    buttons: [.keep, .cancel, .endEverything], showsSuppression: false)
        }
        guard prompt.offersSessionChoice else {
            return QuitAlertContent(title: ConfirmationStrings.quitIncognitoTitle, lines: [], buttons: [.quit, .cancel],
                                    showsSuppression: false)
        }
        // Statuses only, no explanation of what quitting does.
        var lines: [String] = []
        if prompt.runningPrograms > 0 { lines.append(QuitStrings.programsRunning(prompt.runningPrograms)) }
        if prompt.agentsInTurn > 0 { lines.append(QuitStrings.agentsWorking(prompt.agentsInTurn)) }
        if !prompt.incognitoPrograms.isEmpty { lines.append(QuitStrings.incognitoCloses) }
        return QuitAlertContent(title: QuitStrings.title, lines: lines, buttons: [.keep, .endKeepLayout, .endEverything, .cancel],
                                showsSuppression: true)
    }

    static func title(of button: Button) -> String {
        switch button {
        case .keep: QuitStrings.keepSessionsRunning
        case .quit: ConfirmationStrings.quit
        case .cancel: ConfirmationStrings.cancel
        case .endKeepLayout: QuitStrings.endKeepLayout
        case .endEverything: QuitStrings.endEverything
        }
    }
}
