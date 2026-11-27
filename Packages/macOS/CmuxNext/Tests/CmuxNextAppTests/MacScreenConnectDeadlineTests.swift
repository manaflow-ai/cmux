@testable import CmuxNextMacScreen
import CmuxScreenKit
import Foundation
import Testing

/// A viewer's connect has 15 s to show a picture, then fails naming the stage it reached (no
/// answer, no link, no frame), and the failed card says that stage instead of "Connecting..."
/// forever or the generic "awake and online" (cmuxterm-hq#13721).
@MainActor @Suite struct MacScreenConnectDeadlineTests {
    static func session() -> MacScreenSession {
        MacScreenSession(title: "Studio", preferences: ScreenPreferences(), signaling: { nil })
    }

    @Test func stagesOnlyMoveForward() {
        let session = Self.session()
        #expect(session.connectStage == .answer)
        session.reach(.frame)
        session.reach(.link)
        #expect(session.connectStage == .frame)
        session.reach(.shown)
        session.reach(.answer)
        #expect(session.connectStage == .shown)
    }

    @Test(arguments: [
        (MacScreenConnectStage.answer, "No answer from Studio within 15 seconds."),
        (.link, "Studio answered, but no link came up within 15 seconds."),
        (.frame, "Connected to Studio, but no picture arrived within 15 seconds."),
    ])
    func aTimedOutConnectFailsNamingItsStage(stage: MacScreenConnectStage, text: String) {
        let session = Self.session()
        session.reach(stage)
        session.connectTimedOut()
        #expect(session.timedOutStage == stage)
        #expect(session.phase == .failed(message: text, needsSignIn: false))
        // The card says the stage, not the generic "awake and online".
        let detail = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: false, hubTab: true, name: "Studio",
                                                     timedOut: session.timedOutStage)
        #expect(detail == text)
        // This Mac's own hub socket being down never hides the stage it stopped at.
        let offline = MacScreenPaneModel.failedDetail(relayErrors: [], relayOnly: false, hubTab: true, name: "Studio",
                                                      hubOnline: false, timedOut: stage)
        #expect(offline == text)
    }

    @Test func aShownPictureNeverTimesOut() {
        let session = Self.session()
        session.reach(.shown)
        session.connectTimedOut()
        #expect(session.timedOutStage == nil)
        #expect(session.phase == .ended)
    }

    @Test func stageNamesAreTheStateRowsWords() {
        #expect([MacScreenConnectStage.answer, .link, .frame, .shown].map(\.name) == ["no_answer", "no_link", "no_frame", "shown"])
    }
}
