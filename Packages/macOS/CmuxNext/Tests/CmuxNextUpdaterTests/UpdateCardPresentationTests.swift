import Testing
@testable import CmuxNextUpdater

/// What the R114 card says in each state.
@Suite struct UpdateCardPresentationTests {
    @Test func aStagedUpdateAsksForTheOneClickRestart() {
        let ready = UpdateCard.ready(version: "1.0.0-nightly.9").presentation
        #expect(ready.title == UpdaterStrings.restartToUpdate)
        #expect(ready.detail == UpdaterStrings.cardReadyDetail("1.0.0-nightly.9"))
        #expect(ready.accent)
        #expect(ready.buttons.isEmpty)
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
        #expect(UpdateCard.available(version: "5").presentation.detail == UpdaterStrings.cardAvailableDetail("5"))
        #expect(UpdateCard.note("x", isError: true).presentation.title == "x")
        #expect(UpdateCard.installing.presentation.title == UpdaterStrings.installing)
        #expect(UpdateCard.checking.presentation.title == UpdaterStrings.checking)
    }
}
