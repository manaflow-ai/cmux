import CmuxNextDesign
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextDaemon

/// OSC 7501 notifications (cx-kxa2): the daemon posts a `terminal`
/// notification when a record changes into blocked, error or done; the app
/// recognizes it by the terminal's record (its kind picks the badge) and
/// shows a `done` only for a terminal the user cannot see.
struct ProgramStatusNotificationTests {
    static let records = [
        ProgramStatusRecord(state: .working, app: "cargo", title: "Build", updatedSeq: 1),
        ProgramStatusRecord(id: "deploy", state: .blocked, kind: .question, app: "claude", title: "Deploy",
                            msg: "Which env?", updatedSeq: 2),
        ProgramStatusRecord(id: "tests", state: .done, app: "cargo", updatedSeq: 3),
        ProgramStatusRecord(id: "lint", state: .error, title: "Lint", msg: "exit 1", updatedSeq: 4),
    ]

    @Test func theDaemonsNoticeFindsItsRecord() {
        let blocked = ProgramStatusNotification.match(title: "Deploy", body: "Which env?", level: .warning, records: Self.records)
        #expect(blocked?.record.id == "deploy")
        #expect(blocked?.reason == .question)
        // No title: the daemon used the app name.
        #expect(ProgramStatusNotification.match(title: "cargo", body: "", level: .info, records: Self.records)?.reason == .done)
        #expect(ProgramStatusNotification.match(title: "Lint", body: "exit 1", level: .error, records: Self.records)?.reason == .failed)
    }

    @Test func otherTerminalNotificationsAreNotProgramStatus() {
        // OSC 9 / 777 text, or a level that does not match the record's state.
        #expect(ProgramStatusNotification.match(title: "nine", body: "", level: .info, records: Self.records) == nil)
        #expect(ProgramStatusNotification.match(title: "Deploy", body: "Which env?", level: .error, records: Self.records) == nil)
        #expect(ProgramStatusNotification.match(title: "Build", body: "", level: .info, records: Self.records) == nil)
    }

    @Test func blockedReasonsFollowTheKind() {
        func reason(_ kind: ProgramStatusRecord.Kind?) -> ProgramStatusNotification.Reason? {
            let record = ProgramStatusRecord(state: .blocked, kind: kind, title: "T", updatedSeq: 1)
            return ProgramStatusNotification.match(title: "T", body: "", level: .warning, records: [record])?.reason
        }
        #expect(reason(.permission) == .permission)
        #expect(reason(.question) == .question)
        #expect(reason(.auth) == .auth)
        #expect(reason(nil) == .input)
    }

    @Test func doneShowsOnlyForATerminalTheUserCannotSee() throws {
        let done = try #require(ProgramStatusNotification.match(title: "cargo", body: "", level: .info, records: Self.records))
        let blocked = try #require(ProgramStatusNotification.match(title: "Deploy", body: "Which env?", level: .warning, records: Self.records))
        let visible = TerminalVisibility(tabSelected: true, paneOnScreen: true, windowShown: true, appActive: true)
        var behind = visible
        behind.tabSelected = false
        #expect(!done.notifies(visibility: visible))
        #expect(done.notifies(visibility: behind))
        #expect(done.notifies(visibility: .hidden))
        // Needs-you and failures always go through the normal notification rules.
        #expect(blocked.notifies(visibility: visible))
    }

    @Test func eachReasonHasAnIndicatorState() {
        #expect(ProgramStatusNotification.Reason.permission.indicator == .waiting)
        #expect(ProgramStatusNotification.Reason.failed.indicator == .error)
        #expect(ProgramStatusNotification.Reason.done.indicator == .success)
    }
}
