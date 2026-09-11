import Testing
@testable import CmuxMobileTerminalKit

@Suite struct TerminalInputSessionReducerTests {
    @Test func failedFocusNeverClaimsTheResponderAndTheNextTapRetries() {
        var state = TerminalInputSessionState()

        let initial = state.handle(.requestFocus(.terminal))
        #expect(initial.commands == [.focus(.terminal)])
        #expect(state.requestedOwner == .terminal)
        #expect(state.actualOwner == nil)

        let failed = state.handle(.focusCompleted(owner: .terminal, succeeded: false))
        #expect(failed.commands.isEmpty)
        #expect(state.requestedOwner == .terminal)
        #expect(state.actualOwner == nil)

        let retry = state.handle(.requestFocus(.terminal))
        #expect(retry.commands == [.focus(.terminal)])
        #expect(state.actualOwner == nil)

        _ = state.handle(.focusCompleted(owner: .terminal, succeeded: true))
        #expect(state.requestedOwner == .terminal)
        #expect(state.actualOwner == .terminal)
    }

    @Test func twentyRapidTerminalTapsSettleOnOneTerminalOwner() {
        var state = TerminalInputSessionState()

        for tapIndex in 0..<20 {
            let transition = state.handle(.terminalTapped(.immediateInput))
            if tapIndex == 0 {
                #expect(transition.commands == [.focus(.terminal)])
                _ = state.handle(.focusCompleted(owner: .terminal, succeeded: true))
            } else {
                #expect(transition.commands.isEmpty)
            }
        }

        #expect(state.requestedOwner == .terminal)
        #expect(state.actualOwner == .terminal)
    }

    @Test func immediateTapIsNeverQueuedBehindAnOlderDeferredArtifactDecision() throws {
        var state = TerminalInputSessionState()

        let deferred = state.handle(.terminalTapped(.deferForArtifactDecision))
        let deferredTapID = try #require(deferred.deferredTapID)
        #expect(deferred.commands.isEmpty)
        #expect(state.requestedOwner == nil)

        let immediate = state.handle(.terminalTapped(.immediateInput))
        #expect(immediate.commands == [.focus(.terminal)])
        _ = state.handle(.focusCompleted(owner: .terminal, succeeded: true))

        let staleResolution = state.handle(
            .deferredTerminalTapResolved(id: deferredTapID, resolution: .focusTerminal)
        )
        #expect(staleResolution.commands.isEmpty)
        #expect(state.actualOwner == .terminal)
    }

    @Test func cachedArtifactTapDefersWithoutFlashingTheKeyboard() throws {
        var state = TerminalInputSessionState()

        let artifactTap = state.handle(.terminalTapped(.deferForArtifactDecision))
        let artifactTapID = try #require(artifactTap.deferredTapID)
        #expect(artifactTap.commands.isEmpty)

        let opened = state.handle(
            .deferredTerminalTapResolved(id: artifactTapID, resolution: .artifactHandled)
        )
        #expect(opened.commands.isEmpty)
        #expect(state.requestedOwner == nil)
        #expect(state.actualOwner == nil)

        let terminalTap = state.handle(.terminalTapped(.deferForArtifactDecision))
        let terminalTapID = try #require(terminalTap.deferredTapID)
        let resolved = state.handle(
            .deferredTerminalTapResolved(id: terminalTapID, resolution: .focusTerminal)
        )
        #expect(resolved.commands == [.focus(.terminal)])
    }

    @Test func staleArtifactSnapshotDefersWhenAPathCouldHaveAppearedAfterTheCache() {
        let staleSnapshot = TerminalInputTapIntent.artifactAware(
            artifactDetectionEnabled: true,
            currentSnapshotGeneration: 42,
            cachedSnapshotGeneration: 41,
            cachedSnapshotContainsCandidate: false
        )
        #expect(staleSnapshot == .deferForArtifactDecision)

        let missingSnapshot = TerminalInputTapIntent.artifactAware(
            artifactDetectionEnabled: true,
            currentSnapshotGeneration: 42,
            cachedSnapshotGeneration: nil,
            cachedSnapshotContainsCandidate: false
        )
        #expect(missingSnapshot == .deferForArtifactDecision)

        let freshTerminalCell = TerminalInputTapIntent.artifactAware(
            artifactDetectionEnabled: true,
            currentSnapshotGeneration: 42,
            cachedSnapshotGeneration: 42,
            cachedSnapshotContainsCandidate: false
        )
        #expect(freshTerminalCell == .immediateInput)
    }

    @Test func terminalComposerHandoffHasOneRequestedAndActualOwner() {
        var state = TerminalInputSessionState()

        _ = state.handle(.requestFocus(.terminal))
        _ = state.handle(.focusCompleted(owner: .terminal, succeeded: true))

        let composer = state.handle(.requestFocus(.composer))
        #expect(composer.commands == [.focus(.composer)])
        #expect(state.requestedOwner == .composer)
        #expect(state.actualOwner == .terminal)
        _ = state.handle(.focusCompleted(owner: .composer, succeeded: true))
        #expect(state.requestedOwner == .composer)
        #expect(state.actualOwner == .composer)

        let terminal = state.handle(.requestFocus(.terminal))
        #expect(terminal.commands == [.focus(.terminal)])
        _ = state.handle(.focusCompleted(owner: .terminal, succeeded: true))
        #expect(state.requestedOwner == .terminal)
        #expect(state.actualOwner == .terminal)
    }

    @Test func visibleFocusRequestReassertsUIKitFocusWhenAlreadyOwned() {
        var state = TerminalInputSessionState()

        _ = state.handle(.requestFocus(.terminal))
        _ = state.handle(.focusCompleted(owner: .terminal, succeeded: true))

        let repeatRequest = state.handle(.requestVisibleFocus(.terminal))
        #expect(repeatRequest.commands == [.focus(.terminal)])
        #expect(state.requestedOwner == .terminal)
        #expect(state.actualOwner == .terminal)
    }

    @Test func failedHandoffKeepsTheActualOwnerUntilACommandSucceeds() {
        var state = TerminalInputSessionState()
        _ = state.handle(.requestFocus(.composer))
        _ = state.handle(.focusCompleted(owner: .composer, succeeded: true))

        _ = state.handle(.requestFocus(.terminal))
        _ = state.handle(.focusCompleted(owner: .terminal, succeeded: false))
        #expect(state.requestedOwner == .terminal)
        #expect(state.actualOwner == .composer)

        let retry = state.handle(.terminalTapped(.immediateInput))
        #expect(retry.commands == [.focus(.terminal)])
        #expect(state.actualOwner == .composer)
    }

    @Test func photoPickerWillPresentResignsTheCurrentOwner() {
        var state = TerminalInputSessionState()
        _ = state.handle(.requestFocus(.composer))
        _ = state.handle(.focusCompleted(owner: .composer, succeeded: true))

        let willPresent = state.handle(.modalWillPresent)
        #expect(state.modalPhase == .willPresent)
        #expect(state.requestedOwner == nil)
        #expect(state.actualOwner == .composer)
        #expect(willPresent.commands == [.resign(.composer)])

        _ = state.handle(.resignCompleted(owner: .composer, succeeded: true))
        #expect(state.actualOwner == nil)
        #expect(state.modalPhase == .willPresent)

        _ = state.handle(.modalDidPresent)
        #expect(state.modalPhase == .presented)
        #expect(state.actualOwner == nil)
    }

    @Test func focusRequestedDuringPickerDismissalRunsAtDidDismissBoundary() {
        var state = TerminalInputSessionState()
        _ = state.handle(.modalWillPresent)
        _ = state.handle(.modalDidPresent)
        let tapDuringDismissal = state.handle(.requestFocus(.terminal))
        #expect(tapDuringDismissal.commands.isEmpty)
        #expect(state.requestedOwner == .terminal)
        #expect(state.actualOwner == nil)

        let didDismiss = state.handle(.modalDidDismiss)
        #expect(state.modalPhase == .none)
        #expect(didDismiss.commands == [.focus(.terminal)])
    }

    @Test func pickerCancelWithoutWillDismissStillRestoresDeferredFocus() {
        var state = TerminalInputSessionState()
        _ = state.handle(.modalWillPresent)
        _ = state.handle(.modalDidPresent)
        _ = state.handle(.requestFocus(.composer))

        let didDismiss = state.handle(.modalDidDismiss)
        #expect(state.modalPhase == .none)
        #expect(state.requestedOwner == .composer)
        #expect(didDismiss.commands == [.focus(.composer)])
    }

    @Test func sceneBoundaryResignsAndRetriesOnlyARequestMadeWhileInactive() {
        var state = TerminalInputSessionState()
        _ = state.handle(.requestFocus(.terminal))
        _ = state.handle(.focusCompleted(owner: .terminal, succeeded: true))

        let inactive = state.handle(.sceneWillResignActive)
        #expect(state.scenePhase == .inactive)
        #expect(state.requestedOwner == nil)
        #expect(inactive.commands == [.resign(.terminal)])
        _ = state.handle(.resignCompleted(owner: .terminal, succeeded: true))

        let requestWhileInactive = state.handle(.requestFocus(.composer))
        #expect(requestWhileInactive.commands.isEmpty)
        #expect(state.requestedOwner == .composer)

        let active = state.handle(.sceneDidBecomeActive)
        #expect(state.scenePhase == .active)
        #expect(active.commands == [.focus(.composer)])
    }

    @Test func surfaceDetachClearsInputWithoutMisreportingTheActiveScene() {
        var state = TerminalInputSessionState()
        _ = state.handle(.requestFocus(.terminal))
        _ = state.handle(.focusCompleted(owner: .terminal, succeeded: true))

        let detached = state.handle(.surfaceDetached)
        #expect(state.scenePhase == .active)
        #expect(state.requestedOwner == nil)
        #expect(state.actualOwner == .terminal)
        #expect(detached.commands == [.resign(.terminal)])
    }

    @Test func lifecycleBoundaryFocusesARetainedComposerRequestAfterMount() {
        var state = TerminalInputSessionState()
        _ = state.handle(.requestFocus(.composer))
        _ = state.handle(.focusCompleted(owner: .composer, succeeded: false))

        let mounted = state.handle(.lifecycleBoundary)
        #expect(mounted.commands == [.focus(.composer)])
    }

    @Test func responderObservationCannotLeaveAnOwnerActiveUnderAModal() {
        var state = TerminalInputSessionState()
        _ = state.handle(.modalWillPresent)
        _ = state.handle(.modalDidPresent)

        let unexpected = state.handle(
            .responderChanged(owner: .terminal, isFirstResponder: true)
        )
        #expect(state.actualOwner == .terminal)
        #expect(unexpected.commands == [.resign(.terminal)])

        _ = state.handle(.resignCompleted(owner: .terminal, succeeded: true))
        #expect(state.actualOwner == nil)
    }
}
