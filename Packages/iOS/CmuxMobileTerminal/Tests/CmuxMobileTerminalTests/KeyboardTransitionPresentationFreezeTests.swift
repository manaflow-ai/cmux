#if canImport(UIKit)
import Testing
@testable import CmuxMobileTerminal

@Suite("Keyboard transition presentation freeze")
struct KeyboardTransitionPresentationFreezeTests {
    @Test("the frozen frame stays until the TUI redraw for the target grid presents")
    func revealWaitsForRedrawAfterConfirmedResize() {
        var freeze = KeyboardTransitionPresentationFreeze()
        freeze.noteReportPublished(id: 7)
        var presented = freeze.notePresented(token: 10)
        #expect(!presented)

        // UIKit finished moving the pane, but the Mac has not resized the PTY:
        // any frame now is the old TUI reflowed into the new grid.
        freeze.noteTransitionEnded()
        presented = freeze.notePresented(token: 11)
        #expect(!presented)

        // Output that arrives before the confirmation predates the resize.
        freeze.noteOutputApplied(lastIssuedToken: 11)
        presented = freeze.notePresented(token: 12)
        #expect(!presented)

        freeze.noteReportConfirmed(id: 7)
        presented = freeze.notePresented(token: 13)
        #expect(!presented)

        freeze.noteOutputApplied(lastIssuedToken: 13)
        // A submission issued before the redraw was applied cannot carry it.
        presented = freeze.notePresented(token: 13)
        #expect(!presented)
        presented = freeze.notePresented(token: 14)
        #expect(presented)
    }

    @Test("the redraw may land before UIKit finishes the keyboard leg")
    func redrawBeforeLegEndRevealsOnFirstPresentAfterLegEnd() {
        var freeze = KeyboardTransitionPresentationFreeze()
        freeze.noteReportPublished(id: 3)
        freeze.noteReportConfirmed(id: 3)
        freeze.noteOutputApplied(lastIssuedToken: 20)
        var presented = freeze.notePresented(token: 21)
        #expect(!presented)
        freeze.noteTransitionEnded()
        presented = freeze.notePresented(token: 22)
        #expect(presented)
    }

    @Test("an echo for a superseded report does not release the freeze")
    func staleEchoIsIgnored() {
        var freeze = KeyboardTransitionPresentationFreeze()
        freeze.noteReportPublished(id: 4)
        freeze.noteReportPublished(id: 5)
        freeze.noteTransitionEnded()
        freeze.noteReportConfirmed(id: 4)
        freeze.noteOutputApplied(lastIssuedToken: 30)
        let presented = freeze.notePresented(token: 31)
        #expect(!presented)
    }

    @Test("an unchanged target grid needs no PTY round trip")
    func unchangedGridRevealsAfterLegEnd() {
        var freeze = KeyboardTransitionPresentationFreeze()
        freeze.noteReportUnneeded(lastIssuedToken: 40)
        var presented = freeze.notePresented(token: 41)
        #expect(!presented)
        freeze.noteTransitionEnded()
        presented = freeze.notePresented(token: 42)
        #expect(presented)
    }
}
#endif
