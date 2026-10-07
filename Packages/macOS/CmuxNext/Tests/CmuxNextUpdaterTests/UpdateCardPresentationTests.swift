import Testing
@testable import CmuxNextUpdater

/// What the R114 card says for a check the user asked for, and what the
/// footer pill says (SIDEBAR-FOOTER-MINIMAL).
@Suite struct UpdateCardPresentationTests {
    /// The pill reads "Update Ready"; its tooltip and VoiceOver label say
    /// that terminals and agents keep running (the relaunch keeps them).
    @Test func theFooterPillSaysUpdateReadyAndThatSessionsKeepRunning() {
        #expect(UpdateFooterPill.ready.title == UpdaterStrings.readyToInstall)
        #expect(UpdateFooterPill.ready.help == UpdaterStrings.restartKeepsSessions)
        #expect(UpdateFooterPill.ready.isEnabled)
        #expect(UpdateFooterPill.installing.title == UpdaterStrings.installing)
        #expect(!UpdateFooterPill.installing.isEnabled)
    }

    @Test func progressAndNotes() {
        #expect(UpdateCard.downloading(progress: 0.4).presentation.progress == 0.4)
        #expect(UpdateCard.downloading(progress: 0.4).presentation.title == UpdaterStrings.downloading)
        #expect(UpdateCard.note("x", isError: true).presentation.title == "x")
        #expect(UpdateCard.checking.presentation.title == UpdaterStrings.checking)
    }
}
