import Testing
@testable import CmuxSettingsUI

/// The three-tier backend-environment card visibility: full picker for
/// gate-allowed/DEBUG, recovery for everyone else off production (or with a
/// switch in flight), hidden otherwise.
@Suite("BackendEnvironmentCardVisibility")
struct BackendEnvironmentCardVisibilityTests {
    private static let allPhases: [AccountBackendEnvironmentSwitchPhase] = [
        .idle, .parking, .retargeting, .establishing, .reverting,
        .finished(.switched),
        .finished(.reverted(.signInCancelled)),
        .finished(.reverted(.signInFailed)),
        .finished(.reverted(.notEligible)),
    ]

    @Test func pickerAllowedIsAlwaysFullPickerAcrossEnvironmentsAndPhases() {
        for environment in AccountBackendEnvironment.allCases {
            for phase in Self.allPhases {
                #expect(
                    BackendEnvironmentCardVisibility(
                        pickerAllowed: true,
                        activeEnvironment: environment,
                        switchPhase: phase
                    ) == .fullPicker
                )
            }
        }
    }

    @Test func nonGateUserOnStagingGetsRecovery() {
        #expect(
            BackendEnvironmentCardVisibility(
                pickerAllowed: false,
                activeEnvironment: .staging,
                switchPhase: .idle
            ) == .recovery
        )
    }

    @Test func nonGateUserOnProductionIdleIsHidden() {
        #expect(
            BackendEnvironmentCardVisibility(
                pickerAllowed: false,
                activeEnvironment: .production,
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
                    activeEnvironment: .production,
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
