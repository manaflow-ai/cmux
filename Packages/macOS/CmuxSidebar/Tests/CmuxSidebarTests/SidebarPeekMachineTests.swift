import Foundation
import Testing
@testable import CmuxSidebar

@Suite("SidebarPeekMachine")
struct SidebarPeekMachineTests {
    private let machine = SidebarPeekMachine(policy: .default)

    private func armedAndRevealed() -> SidebarPeekState {
        var state = SidebarPeekState.idle
        machine.apply(.pointerEnteredEdge, to: &state)
        machine.apply(.dwellElapsed, to: &state)
        return state
    }

    // MARK: - Reveal

    @Test func restingAtTheEdgeArmsDwellBeforeRevealing() {
        var state = SidebarPeekState.idle
        let effects = machine.apply(.pointerEnteredEdge, to: &state)
        #expect(state.phase == .arming)
        #expect(!state.presentsPanel)
        #expect(effects == [.startDwellTimer])
    }

    @Test func dwellElapsingRevealsThePanel() {
        var state = SidebarPeekState.idle
        machine.apply(.pointerEnteredEdge, to: &state)
        let effects = machine.apply(.dwellElapsed, to: &state)
        #expect(state.phase == .peeking)
        #expect(state.presentsPanel)
        #expect(effects.isEmpty)
    }

    @Test func crossingTheEdgeWithoutRestingNeverReveals() {
        // The whole point of dwell: a pointer travelling to a terminal passes
        // through the edge strip constantly and must not flash the sidebar.
        var state = SidebarPeekState.idle
        machine.apply(.pointerEnteredEdge, to: &state)
        let effects = machine.apply(.pointerExitedEdge, to: &state)
        #expect(state.phase == .idle)
        #expect(!state.presentsPanel)
        #expect(effects == [.cancelDwellTimer])
    }

    @Test func aDragSkipsDwellEntirely() {
        var state = SidebarPeekState.idle
        let effects = machine.apply(.dragEnteredEdge, to: &state)
        #expect(state.phase == .peeking)
        #expect(state.holds.contains(.dragInFlight))
        #expect(effects.contains(.cancelDwellTimer))
    }

    @Test func disabledPolicyNeverReveals() {
        let disabled = SidebarPeekMachine(policy: SidebarPeekPolicy(
            dwell: .milliseconds(180),
            grace: .milliseconds(260),
            edgeWidth: 6,
            dismissesOnWorkspaceActivation: true,
            isEnabled: false
        ))
        var state = SidebarPeekState.idle
        #expect(disabled.apply(.pointerEnteredEdge, to: &state).isEmpty)
        #expect(disabled.apply(.dragEnteredEdge, to: &state).isEmpty)
        #expect(state.phase == .idle)
    }

    // MARK: - Dismissal

    @Test func leavingTheEdgeStartsGraceRatherThanDismissingOutright() {
        var state = armedAndRevealed()
        let effects = machine.apply(.pointerExitedEdge, to: &state)
        #expect(state.phase == .dismissing)
        // Still drawn: grace is what lets the pointer travel the diagonal from
        // the edge strip into the panel without the panel vanishing en route.
        #expect(state.presentsPanel)
        #expect(effects == [.startGraceTimer])
    }

    @Test func returningToTheEdgeDuringGraceCancelsDismissal() {
        var state = armedAndRevealed()
        machine.apply(.pointerExitedEdge, to: &state)
        let effects = machine.apply(.pointerEnteredEdge, to: &state)
        #expect(state.phase == .peeking)
        #expect(effects == [.cancelGraceTimer])
    }

    @Test func graceElapsingWithNoHoldDismisses() {
        var state = armedAndRevealed()
        machine.apply(.pointerExitedEdge, to: &state)
        machine.apply(.graceElapsed, to: &state)
        #expect(state.phase == .idle)
        #expect(!state.presentsPanel)
    }

    @Test func enteringThePanelDuringGraceKeepsItOpen() {
        var state = armedAndRevealed()
        machine.apply(.pointerExitedEdge, to: &state)
        let effects = machine.apply(.holdAcquired(.pointerInsidePanel), to: &state)
        #expect(state.phase == .peeking)
        #expect(effects.contains(.cancelGraceTimer))
    }

    // MARK: - Holds

    @Test(arguments: [
        SidebarPeekHold.contextMenuOpen,
        SidebarPeekHold.keyboardFocusInside,
        SidebarPeekHold.dragInFlight,
    ])
    func aHoldRefusesDismissalWhileThePointerIsElsewhere(hold: SidebarPeekHold) {
        var state = armedAndRevealed()
        machine.apply(.holdAcquired(hold), to: &state)
        let effects = machine.apply(.pointerExitedEdge, to: &state)
        #expect(state.phase == .peeking)
        #expect(effects.isEmpty)
    }

    @Test func openingAContextMenuSurvivesThePointerLeavingThePanel() {
        // The classic hover-panel bug: a context menu is its own window, so
        // opening one moves the pointer out of the panel and the panel
        // dismisses under the menu the user just opened.
        var state = armedAndRevealed()
        machine.apply(.holdAcquired(.pointerInsidePanel), to: &state)
        machine.apply(.holdAcquired(.contextMenuOpen), to: &state)
        machine.apply(.holdReleased(.pointerInsidePanel), to: &state)
        #expect(state.phase == .peeking)
    }

    @Test func releasingTheLastHoldStartsGrace() {
        var state = armedAndRevealed()
        machine.apply(.holdAcquired(.pointerInsidePanel), to: &state)
        machine.apply(.holdAcquired(.contextMenuOpen), to: &state)
        #expect(machine.apply(.holdReleased(.contextMenuOpen), to: &state).isEmpty)
        let effects = machine.apply(.holdReleased(.pointerInsidePanel), to: &state)
        #expect(state.phase == .dismissing)
        #expect(effects == [.startGraceTimer])
    }

    @Test func aHoldAcquiredMidGraceWinsOverTheTimerThatAlreadyFired() {
        // The grace timer cannot be un-fired once scheduled, so a hold taken
        // between scheduling and firing has to be re-checked at fire time.
        var state = armedAndRevealed()
        machine.apply(.pointerExitedEdge, to: &state)
        state.insert(.keyboardFocusInside)
        let effects = machine.apply(.graceElapsed, to: &state)
        #expect(state.phase == .peeking)
        #expect(effects == [.cancelGraceTimer])
    }

    @Test func typingInTheFilterKeepsThePanelOpenWithThePointerAway() {
        var state = armedAndRevealed()
        machine.apply(.holdAcquired(.keyboardFocusInside), to: &state)
        machine.apply(.pointerExitedEdge, to: &state)
        machine.apply(.graceElapsed, to: &state)
        #expect(state.presentsPanel)
    }

    // MARK: - Explicit exits

    @Test func activatingAWorkspaceDismissesImmediatelyWithoutGrace() {
        var state = armedAndRevealed()
        machine.apply(.holdAcquired(.pointerInsidePanel), to: &state)
        let effects = machine.apply(.workspaceActivated, to: &state)
        #expect(state.phase == .idle)
        #expect(state.holds.isEmpty)
        #expect(!effects.contains(.startGraceTimer))
    }

    @Test func activationCanBeConfiguredToLeaveThePanelOpen() {
        let sticky = SidebarPeekMachine(policy: SidebarPeekPolicy(
            dwell: .milliseconds(180),
            grace: .milliseconds(260),
            edgeWidth: 6,
            dismissesOnWorkspaceActivation: false,
            isEnabled: true
        ))
        var state = SidebarPeekState.idle
        sticky.apply(.pointerEnteredEdge, to: &state)
        sticky.apply(.dwellElapsed, to: &state)
        sticky.apply(.workspaceActivated, to: &state)
        #expect(state.phase == .peeking)
    }

    @Test func escapeDismissesThroughEveryHold() {
        var state = armedAndRevealed()
        machine.apply(.holdAcquired(.pointerInsidePanel), to: &state)
        machine.apply(.holdAcquired(.contextMenuOpen), to: &state)
        machine.apply(.escapePressed, to: &state)
        #expect(state.phase == .idle)
        #expect(state.holds.isEmpty)
    }

    @Test func dockingTheSidebarClearsEveryHoldSoPeekCannotStrand() {
        var state = armedAndRevealed()
        machine.apply(.holdAcquired(.contextMenuOpen), to: &state)
        let effects = machine.apply(.sidebarDocked, to: &state)
        #expect(state.phase == .idle)
        #expect(state.holds.isEmpty)
        #expect(effects.contains(.cancelDwellTimer))
        #expect(effects.contains(.cancelGraceTimer))
    }

    // MARK: - Robustness

    @Test func staleTimerEventsInTheWrongPhaseAreIgnored() {
        // Timers fire from outside the machine and can outlive the phase that
        // scheduled them; every one has to be a no-op rather than a jump.
        var state = SidebarPeekState.idle
        #expect(machine.apply(.dwellElapsed, to: &state).isEmpty)
        #expect(state.phase == .idle)
        #expect(machine.apply(.graceElapsed, to: &state).isEmpty)
        #expect(state.phase == .idle)

        var peeking = armedAndRevealed()
        #expect(machine.apply(.dwellElapsed, to: &peeking).isEmpty)
        #expect(peeking.phase == .peeking)
    }

    @Test func repeatedEdgeEntriesDoNotRestartDwell() {
        var state = SidebarPeekState.idle
        machine.apply(.pointerEnteredEdge, to: &state)
        // A jittering pointer re-entering the strip must not push the reveal
        // further away by restarting the countdown each time.
        let effects = machine.apply(.pointerEnteredEdge, to: &state)
        #expect(effects.isEmpty)
        #expect(state.phase == .arming)
    }

    @Test func everyPhaseAgreesWithItsPanelVisibility() {
        for phase in SidebarPeekPhase.allCases {
            let state = SidebarPeekState(phase: phase, holds: [])
            #expect(state.presentsPanel == phase.presentsPanel)
        }
    }
}
