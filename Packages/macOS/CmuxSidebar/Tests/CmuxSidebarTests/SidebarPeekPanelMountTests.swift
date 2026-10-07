import Testing
@testable import CmuxSidebar

@Suite("SidebarPeekPanelMount")
struct SidebarPeekPanelMountTests {
    @Test func dockedVisibleSidebarNeverMountsTheCard() {
        // The typing setup most people keep: no second list behind it.
        for peekEnabled in [false, true] {
            for peekPresenting in [false, true] {
                #expect(!SidebarPeekPanelMount.isNeeded(
                    sidebarVisible: true,
                    presentationMode: .docked,
                    peekEnabled: peekEnabled,
                    peekPresenting: peekPresenting
                ))
            }
        }
    }

    @Test func floatingVisibleSidebarMountsTheCard() {
        #expect(SidebarPeekPanelMount.isNeeded(
            sidebarVisible: true,
            presentationMode: .floating,
            peekEnabled: false,
            peekPresenting: false
        ))
    }

    @Test(arguments: [SidebarPresentationMode.docked, .floating])
    func hiddenSidebarMountsAheadOfAPeekOnlyWhenPeekIsOn(mode: SidebarPresentationMode) {
        #expect(SidebarPeekPanelMount.isNeeded(
            sidebarVisible: false,
            presentationMode: mode,
            peekEnabled: true,
            peekPresenting: false
        ))
        #expect(!SidebarPeekPanelMount.isNeeded(
            sidebarVisible: false,
            presentationMode: mode,
            peekEnabled: false,
            peekPresenting: false
        ))
    }

    @Test func aPeekStillShowingKeepsTheCardWhilePeekTurnsOff() {
        // The policy can flip off while the card is up; the card leaves
        // through the machine, not by its window vanishing first.
        #expect(SidebarPeekPanelMount.isNeeded(
            sidebarVisible: false,
            presentationMode: .docked,
            peekEnabled: false,
            peekPresenting: true
        ))
    }
}
