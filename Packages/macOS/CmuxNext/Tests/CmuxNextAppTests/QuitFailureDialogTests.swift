@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Testing

/// "Some sessions did not end" is a cmux dialog (R96): Retry (Return) runs
/// the end again, Quit Anyway (Escape) quits with what is left; the agents
/// line (.endAgents) stays; a closed window or SIGTERM answers Quit Anyway.
@MainActor
struct QuitFailureDialogTests {
    static let failures = [
        EndSessionsFailure(step: .shutdownDaemon, message: "timeout"),
        EndSessionsFailure(step: .endAgents, message: "acpmux did not exit"),
    ]

    static func open() -> (QuitFailureAlert, CmuxDialogCenter, () -> [QuitFailureAnswer]) {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answers: [QuitFailureAnswer] = []
        let alert = QuitFailureAlert(failures: failures, center: center) { answers.append($0) }
        alert.present(in: nil)
        return (alert, center, { answers })
    }

    @Test func returnRetriesAndEscapeQuitsAnyway() throws {
        let (alert, center, answers) = Self.open()
        defer { withExtendedLifetime(alert) {} }
        let record = try #require(center.records.first)
        #expect(record.spec.identifier == "cmux.dialog.quitFailure")
        #expect(record.spec.defaultButton?.id == QuitFailureAlert.retryID)
        #expect(record.spec.cancelButton?.id == QuitFailureAlert.quitAnywayID)
        center.key(.return, in: record.id)
        #expect(answers() == [.retry])
        let (again, againCenter, againAnswers) = Self.open()
        defer { withExtendedLifetime(again) {} }
        againCenter.key(.escape, in: try #require(againCenter.records.first?.id))
        #expect(againAnswers() == [.quitAnyway])
    }

    @Test func theAgentsLineStays() throws {
        let (alert, center, _) = Self.open()
        defer { withExtendedLifetime(alert) {} }
        let lines = try #require(center.records.first?.spec.lines)
        #expect(lines.contains(QuitStrings.failedEndAgents("acpmux did not exit")))
        #expect(lines.last == QuitStrings.failedKeepRunning)
    }

    @Test func aDismissalOrSigtermQuitsAnyway() throws {
        let (alert, center, answers) = Self.open()
        defer { withExtendedLifetime(alert) {} }
        center.dismiss(try #require(center.records.first?.id))
        #expect(answers() == [.quitAnyway])
        let (signal, signalCenter, signalAnswers) = Self.open()
        signal.answerQuitAnyway()
        #expect(signalAnswers() == [.quitAnyway])
        #expect(signalCenter.records.isEmpty)
    }

    @Test func automationPressesItsButtons() {
        let (alert, _, answers) = Self.open()
        #expect(alert.press("retry"))
        #expect(!alert.press("nope"))
        #expect(answers() == [.retry])
    }
}
