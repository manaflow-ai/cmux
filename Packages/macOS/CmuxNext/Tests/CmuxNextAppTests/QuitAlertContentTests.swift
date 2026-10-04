@testable import CmuxNextApp
import Testing

/// The quit question (R96, R138): a cmux dialog, "Quit cmux?" with one
/// sentence per fact and no program list; Keep Sessions Running (default),
/// Cancel, and "Quit Everything…" asks once more.
struct QuitAlertContentTests {
    static func prompt(terminals: Int = 12, running: Int = 0, incognito: [String] = [], remote: Bool = false,
                       choice: Bool = true, defaultChoice: QuitSessionsChoice = .keep) -> QuitPrompt {
        QuitPrompt(terminals: terminals, runningPrograms: running, busiest: ["vim"], incognitoPrograms: incognito,
                   remoteSessions: remote, offersSessionChoice: choice, defaultChoice: defaultChoice)
    }

    @Test func idleTerminalsGetOneSentence() {
        let content = QuitAlertContent.main(Self.prompt())
        #expect(content.title == "Quit cmux?")
        #expect(content.lines == ["Your 12 terminals keep running in the background."])
        #expect(content.buttons == [.keep, .cancel, .quitEverything])
        #expect(content.showsSuppression)
    }

    @Test func runningProgramsAddOneSentenceAndNoList() {
        let content = QuitAlertContent.main(Self.prompt(running: 3))
        #expect(content.lines == ["Your 12 terminals keep running in the background.", "3 programs are running."])
        #expect(!content.message.contains("vim"))
    }

    @Test func oneTerminalAndOneProgramReadInTheSingular() {
        let content = QuitAlertContent.main(Self.prompt(terminals: 1, running: 1))
        #expect(content.lines == ["Your 1 terminal keeps running in the background.", "1 program is running."])
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

    @Test func endSessionsAsksOnceWithBothEndChoices() {
        let content = QuitAlertContent.endConfirmation
        #expect(content.title == "End all terminals?")
        #expect(content.buttons == [.confirmQuitEverything, .cancel, .endEverything])
        #expect(content.lines == ["End Everything also deletes your workspaces."])
        #expect(QuitAlertContent.title(of: .quitEverything) == "Quit Everything…")
        #expect(QuitAlertContent.title(of: .keep) == "Keep Sessions Running")
    }
}
