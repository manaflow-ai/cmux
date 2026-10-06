import Testing
@testable import CmuxNextUpdater

/// What the R114 card says in each state.
@Suite struct UpdateCardPresentationTests {
    @Test func aStagedUpdateLabelsTheSettingsControlRestartToUpdate() {
        #expect(UpdateIndicatorPhase.ready(version: "1.0.0-nightly.9").badgeTitle == UpdaterStrings.restartToUpdate)
        #expect(UpdateIndicatorPhase.hidden.badgeTitle == nil)
        #expect(UpdateIndicatorPhase.downloading(progress: 0.5).badgeTitle == nil)
    }

    @Test func aHeldClickNamesTheAgentsAndOffersInstallNowAndLater() {
        let waiting = UpdateCard.waiting(version: "2", busyAgents: 3).presentation
        #expect(waiting.title == UpdaterStrings.cardWaitingTitle)
        #expect(waiting.detail == UpdaterStrings.cardWaitingDetail(3))
        #expect(waiting.buttons == [.installNow, .later])
        #expect(UpdateCardPresentation.Button.installNow.title == UpdaterStrings.installNow)
    }

    @Test func progressAndNotes() {
        #expect(UpdateCard.downloading(progress: 0.4).presentation.progress == 0.4)
        #expect(UpdateCard.downloading(progress: 0.4).presentation.title == UpdaterStrings.downloading)
        #expect(UpdateCard.note("x", isError: true).presentation.title == "x")
        #expect(UpdateCard.installing.presentation.title == UpdaterStrings.installing)
        #expect(UpdateCard.checking.presentation.title == UpdaterStrings.checking)
    }
}
