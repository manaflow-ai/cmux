@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// Review of #31875 (Low): a person's close asks when a terminal gives no answer (the daemon is slow or gone), but the
/// question said "Still running: <tab title>.": a tab title is not a program, and nothing confirmed that one runs.
/// The question must still show, and must say that the terminal gave no answer.
@MainActor @Suite struct CloseQuestionNoAnswerTests {
    @Test func aTerminalThatGivesNoAnswerAsksWithoutCallingItsTitleAProgram() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .pty, title: "build logs"))
        // No connection: the terminal cannot answer.
        let (prompt, _) = await TabCloseGuard.promptAndAnswers(closing: [tab], on: DaemonService(), services: services, confirmed: true)
        let body = try #require(prompt?.body, "a terminal that gave no answer closed with no question")
        #expect(body != ConfirmationStrings.stillRunning(tab.displayTitle), "the question calls the tab title a running program: \(body)")
        #expect(body.contains(tab.displayTitle), "the question does not name the terminal that gave no answer: \(body)")
    }
}
