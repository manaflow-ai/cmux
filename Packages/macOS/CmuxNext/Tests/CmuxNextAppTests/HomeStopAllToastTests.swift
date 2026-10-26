@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextDesign
import Foundation
import Testing

/// The Stop all agents toast (HomeHostView+StopAll) for the daemon's answer: what stopped, a
/// count of the subagents acpmux refused to stop (which and why in the tooltip), and the note
/// about one still starting. A daemon from before #23344 sends no `errors` or `note`, and its
/// toast is as before.
@MainActor
struct HomeStopAllToastTests {
    private let refused = "a2: its turn did not stop: acpmux: session busy"
    private let starting = "a1 is still starting; it stops as soon as it starts."

    @Test func refusalsAndAStartingSubagentShowACountAndTheNote() throws {
        let toast = try CmuxToast.stopAll(decoding: Data(#"""
        {"stopped":true,"subagents":["a1","a3"],"errors":["a2: its turn did not stop: acpmux: session busy"],
         "note":"a1 is still starting; it stops as soon as it starts."}
        """#.utf8))
        #expect(toast.message == [HomeStopAllStrings.stopped(["a1", "a3"]), "1 could not be stopped", starting].joined(separator: "\n"))
        // The tooltip has the refusal, then the note (readable even when the toast cuts it off).
        #expect(toast.detail == [refused, starting].joined(separator: "\n"))
        // Restart is for the ones that stopped: a refused one is not in `subagents`.
        #expect(toast.action?.title == HomeStopAllStrings.restart)
    }

    @Test func everyRefusalIsCountedAndListedInTheDetail() {
        let errors = [refused, "a4: its turn did not stop: acpmux: gone"]
        let answer = ChiefStopAll(stopped: false, subagents: [], errors: errors)
        #expect(HomeStopAllStrings.message(for: answer) == "2 could not be stopped")
        #expect(HomeStopAllStrings.detail(for: answer) == errors.joined(separator: "\n"))
        #expect(CmuxToast.stopAll(answer).action == nil)
    }

    @Test func theChiefStoppingWhileEverySubagentRefusesSaysSo() {
        let answer = ChiefStopAll(stopped: true, subagents: [], errors: [refused])
        #expect(HomeStopAllStrings.message(for: answer) == [HomeStopAllStrings.stoppedChief, "1 could not be stopped"].joined(separator: "\n"))
    }

    @Test func noRefusalAndNoStartingSubagentIsOneLineWithNoDetail() throws {
        let toast = try CmuxToast.stopAll(decoding: Data(#"{"stopped":true,"subagents":["a1","a2"],"errors":[]}"#.utf8))
        #expect(toast.message == HomeStopAllStrings.stopped(["a1", "a2"]))
        #expect(toast.detail == nil)
        #expect(toast.action?.title == HomeStopAllStrings.restart)
    }

    @Test func anOlderDaemonsAnswerShowsTheSameToastAsBefore() throws {
        let stopped = try CmuxToast.stopAll(decoding: Data(#"{"stopped":false,"subagents":["a5"]}"#.utf8))
        #expect(stopped.message == HomeStopAllStrings.stopped(["a5"]))
        #expect(stopped.detail == nil)
        let chiefOnly = try CmuxToast.stopAll(decoding: Data(#"{"stopped":true,"subagents":[]}"#.utf8))
        #expect(chiefOnly.message == HomeStopAllStrings.stoppedChiefOnly)
        #expect(chiefOnly.action == nil)
        let none = try CmuxToast.stopAll(decoding: Data(#"{"stopped":false,"subagents":[]}"#.utf8))
        #expect(none.message == HomeStopAllStrings.stoppedNone)
    }

    /// The note alone (no refusal) is its own line under what stopped, and the tooltip repeats it.
    @Test func aStartingSubagentAloneAddsOnlyTheNote() {
        let answer = ChiefStopAll(stopped: false, subagents: ["a1"], note: starting)
        #expect(HomeStopAllStrings.message(for: answer) == [HomeStopAllStrings.stopped(["a1"]), starting].joined(separator: "\n"))
        #expect(HomeStopAllStrings.detail(for: answer) == starting)
    }

    /// The detail is the message's tooltip and the toast's VoiceOver help; the toast stays short.
    @Test func theToastViewShowsTheDetailOnHoverOfTheMessage() throws {
        let view = CmuxToastView(toast: CmuxToast.stopAll(ChiefStopAll(stopped: false, subagents: ["a1"], errors: [refused])))
        let label = try #require(view.messageLabel)
        #expect(label.themedToolTip == refused)
        #expect(view.accessibilityHelp() == refused)
        #expect(label.stringValue == [HomeStopAllStrings.stopped(["a1"]), "1 could not be stopped"].joined(separator: "\n"))
    }
}
