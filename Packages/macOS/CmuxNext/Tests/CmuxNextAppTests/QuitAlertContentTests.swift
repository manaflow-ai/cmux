@testable import CmuxNextApp
import Testing

/// The quit question (R96, R138, #17501): one cmux dialog, "Quit cmux?"
/// with one sentence per fact and no program list; Keep Sessions Running
/// (default), Cancel, and Quit Everything beside them, never a second step;
/// four buttons did not fit the dialog, so End Everything is the menu's.
struct QuitAlertContentTests {
    static func prompt(terminals: Int = 12, running: Int = 0, incognito: [String] = [], remote: Bool = false,
                       choice: Bool = true, defaultChoice: QuitSessionsChoice = .keep, agentsInTurn: Int = 0) -> QuitPrompt {
        QuitPrompt(terminals: terminals, runningPrograms: running, busiest: ["vim"], incognitoPrograms: incognito,
                   remoteSessions: remote, offersSessionChoice: choice, defaultChoice: defaultChoice, agentsInTurn: agentsInTurn)
    }

    @Test func runningProgramsAskOnceWithEveryChoice() {
        let content = QuitAlertContent.main(Self.prompt(running: 3))
        #expect(content.title == "Quit cmux?")
        #expect(content.lines == ["Your 12 terminals keep running in the background.", "3 programs are running."])
        #expect(content.buttons == [.keep, .cancel, .confirmQuitEverything])
        #expect(content.showsSuppression)
        #expect(!content.message.contains("vim"))
    }

    @Test func oneTerminalAndOneProgramReadInTheSingular() {
        let content = QuitAlertContent.main(Self.prompt(terminals: 1, running: 1))
        #expect(content.lines.prefix(2) == ["Your 1 terminal keeps running in the background.", "1 program is running."])
    }

    /// Agents in a turn are not a warning: they keep running and reattach.
    @Test func workingAgentsSayTheyKeepRunning() {
        let content = QuitAlertContent.main(Self.prompt(terminals: 0, agentsInTurn: 2))
        #expect(content.lines == ["Agents still working: 2. They keep running and reattach when you reopen cmux."])
    }

    @Test func incognitoAndRemoteNotesAppearOnlyWhenRelevant() {
        let content = QuitAlertContent.main(Self.prompt(running: 2, incognito: ["npm"], remote: true))
        #expect(content.lines.count == 4)
        #expect(content.lines[2] == QuitStrings.incognitoCloses)
        #expect(content.lines[3] == "Sessions on other machines are not affected.")
        #expect(!content.message.contains("npm"))
    }

    @Test func onlyIncognitoTerminalsAskQuitOrCancel() {
        let content = QuitAlertContent.main(Self.prompt(terminals: 0, incognito: ["vim"], choice: false))
        #expect(content.title == ConfirmationStrings.quitIncognitoTitle)
        #expect(content.buttons == [.quit, .cancel])
        #expect(!content.showsSuppression)
    }

    @Test func buttonTitles() {
        #expect(QuitAlertContent.title(of: .confirmQuitEverything) == "Quit Everything")
        #expect(QuitAlertContent.title(of: .endEverything) == "End Everything")
        #expect(QuitAlertContent.title(of: .keep) == "Keep Sessions Running")
    }
}
