@testable import CmuxNextApp
import Testing

/// The quit question (R96, R138, #17501): one cmux dialog, "Quit cmux?"
/// with one status per line and no program list; Keep Sessions Running
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
        #expect(content.lines == ["3 programs are running."])
        #expect(content.buttons == [.keep, .cancel, .confirmQuitEverything])
        #expect(content.showsSuppression)
        #expect(!content.message.contains("vim"))
    }

    @Test func oneTerminalAndOneProgramReadInTheSingular() {
        let content = QuitAlertContent.main(Self.prompt(terminals: 1, running: 1))
        #expect(content.lines == ["1 program is running."])
    }

    /// Agents in a turn are a status, not a warning: they keep running and reattach.
    @Test func workingAgentsAreCounted() {
        let content = QuitAlertContent.main(Self.prompt(terminals: 0, agentsInTurn: 2))
        #expect(content.lines == ["Agents still working: 2."])
    }

    @Test func incognitoLineAppearsOnlyWhenRelevant() {
        let content = QuitAlertContent.main(Self.prompt(running: 2, incognito: ["npm"], remote: true))
        #expect(content.lines == ["2 programs are running.", QuitStrings.incognitoCloses])
        #expect(!content.message.contains("npm"))
    }

    @Test func onlyIncognitoTerminalsAskQuitOrCancel() {
        let content = QuitAlertContent.main(Self.prompt(terminals: 0, incognito: ["vim"], choice: false))
        #expect(content.title == ConfirmationStrings.quitIncognitoTitle)
        #expect(content.lines.isEmpty)
        #expect(content.buttons == [.quit, .cancel])
        #expect(!content.showsSuppression)
    }

    @Test func buttonTitles() {
        #expect(QuitAlertContent.title(of: .confirmQuitEverything) == "Quit Everything")
        #expect(QuitAlertContent.title(of: .endEverything) == "End Everything")
        #expect(QuitAlertContent.title(of: .keep) == "Keep Sessions Running")
    }
}
