import Testing
@testable import CmuxSidebar

@Suite("SidebarPresentationMode peek panel mount")
struct SidebarPresentationModePeekPanelTests {
    @Test func dockedVisibleSidebarNeverMountsTheCard() {
        // The typing setup most people keep: no second list behind it.
        for peekEnabled in [false, true] {
            for peekPresenting in [false, true] {
                #expect(!SidebarPresentationMode.docked.needsPeekPanel(
                    sidebarVisible: true,
                    peekEnabled: peekEnabled,
                    peekPresenting: peekPresenting
                ))
            }
        }
    }

    @Test func floatingVisibleSidebarMountsTheCard() {
        #expect(SidebarPresentationMode.floating.needsPeekPanel(
            sidebarVisible: true,
            peekEnabled: false,
            peekPresenting: false
        ))
    }

    @Test(arguments: [SidebarPresentationMode.docked, .floating])
    func hiddenSidebarMountsAheadOfAPeekOnlyWhenPeekIsOn(mode: SidebarPresentationMode) {
        #expect(mode.needsPeekPanel(sidebarVisible: false, peekEnabled: true, peekPresenting: false))
        #expect(!mode.needsPeekPanel(sidebarVisible: false, peekEnabled: false, peekPresenting: false))
    }

    @Test func aPeekStillShowingKeepsTheCardWhilePeekTurnsOff() {
        // The policy can flip off while the card is up; the card leaves
        // through the machine, not by its window vanishing first.
        #expect(SidebarPresentationMode.docked.needsPeekPanel(
            sidebarVisible: false,
            peekEnabled: false,
            peekPresenting: true
        ))
    }
}
