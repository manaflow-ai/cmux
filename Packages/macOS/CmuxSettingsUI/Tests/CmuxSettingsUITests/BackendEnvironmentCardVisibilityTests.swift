import Testing
@testable import CmuxSettingsUI

/// The three-tier backend-environment card visibility: full picker for
/// gate-allowed/DEBUG, recovery for everyone else resolving off production
/// (explicit staging AND a staging lane, or with a switch in flight), hidden
/// otherwise.
@Suite("BackendEnvironmentCardVisibility")
struct BackendEnvironmentCardVisibilityTests {
    private static let allPhases: [AccountBackendEnvironmentSwitchPhase] = [
        .idle, .parking, .retargeting, .establishing, .reverting,
        .finished(.switched),
        .finished(.reverted(.signInCancelled)),
        .finished(.reverted(.signInFailed)),
        .finished(.reverted(.notEligible)),
    ]

    private static let allSelections: [AccountBackendEnvironmentSelection] = [
        .buildLane, .production, .staging,
    ]

    private static let allLanes: [AccountBackendEnvironmentBuildLane] = [
        .production, .staging, .custom(label: "localhost:4123"),
    ]

    @Test func pickerAllowedIsAlwaysFullPickerAcrossSelectionsLanesAndPhases() {
        for selection in Self.allSelections {
            for lane in Self.allLanes {
                for phase in Self.allPhases {
                    #expect(
                        BackendEnvironmentCardVisibility(
                            pickerAllowed: true,
                            selection: selection,
                            buildLane: lane,
                            switchPhase: phase
                        ) == .fullPicker
                    )
                }
            }
        }
    }

    @Test func nonGateUserOnExplicitStagingGetsRecovery() {
        #expect(
            BackendEnvironmentCardVisibility(
                pickerAllowed: false,
                selection: .staging,
                buildLane: .production,
                switchPhase: .idle
            ) == .recovery
        )
    }

    @Test func nonGateUserOnAStagingLaneGetsRecovery() {
        // The lane resolves staging even with no explicit choice: the card
        // must render (its copy explains the bake; the switch-back button is
        // reserved for explicit staging inside the card itself).
        #expect(
            BackendEnvironmentCardVisibility(
                pickerAllowed: false,
                selection: .buildLane,
                buildLane: .staging,
                switchPhase: .idle
            ) == .recovery
        )
    }

    @Test func nonGateUserOnProductionResolvingSelectionsIsHidden() {
        // Lane on a production or custom lane, and explicit production, all
        // resolve production: nothing to recover from.
        #expect(
            BackendEnvironmentCardVisibility(
                pickerAllowed: false,
                selection: .buildLane,
                buildLane: .production,
                switchPhase: .idle
            ) == .hidden
        )
        #expect(
            BackendEnvironmentCardVisibility(
                pickerAllowed: false,
                selection: .buildLane,
                buildLane: .custom(label: "localhost:4123"),
                switchPhase: .idle
            ) == .hidden
        )
        #expect(
            BackendEnvironmentCardVisibility(
                pickerAllowed: false,
                selection: .production,
                buildLane: .staging,
                switchPhase: .idle
            ) == .hidden
        )
    }

    @Test func nonGateUserWithAnyNonIdlePhaseGetsRecoveryEvenOnProduction() {
        // Pins the deliberate deviation: mid-switch the gate clause can drop
        // (parking detaches the user) and the switch-back rebind flips
        // active to production before the run finishes; the phase term keeps
        // one card visible through the whole run and its outcome note.
        for phase in Self.allPhases where phase != .idle {
            #expect(
                BackendEnvironmentCardVisibility(
                    pickerAllowed: false,
                    selection: .buildLane,
                    buildLane: .production,
                    switchPhase: phase
                ) == .recovery,
                "phase \(phase) should keep the recovery card visible"
            )
        }
    }
}

/// The package-local switch phase model the host maps onto.
@Suite("AccountBackendEnvironmentSwitchPhase")
struct AccountBackendEnvironmentSwitchPhaseTests {
    @Test func inFlightCoversExactlyTheTransitionalPhases() {
        #expect(!AccountBackendEnvironmentSwitchPhase.idle.isInFlight)
        #expect(AccountBackendEnvironmentSwitchPhase.parking.isInFlight)
        #expect(AccountBackendEnvironmentSwitchPhase.retargeting.isInFlight)
        #expect(AccountBackendEnvironmentSwitchPhase.establishing.isInFlight)
        #expect(AccountBackendEnvironmentSwitchPhase.reverting.isInFlight)
        #expect(!AccountBackendEnvironmentSwitchPhase.finished(.switched).isInFlight)
        #expect(
            !AccountBackendEnvironmentSwitchPhase
                .finished(.reverted(.notEligible)).isInFlight
        )
    }

    @Test func outcomesCarryTheRevertReason() {
        let reverted = AccountBackendEnvironmentSwitchOutcome.reverted(.signInFailed)
        #expect(reverted != .switched)
        #expect(reverted != .reverted(.signInCancelled))
        #expect(reverted == .reverted(.signInFailed))
    }
}
