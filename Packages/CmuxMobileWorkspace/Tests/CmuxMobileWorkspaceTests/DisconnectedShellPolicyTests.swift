import Testing

@testable import CmuxMobileWorkspace

@Suite struct DisconnectedShellPolicyTests {
    @Test func neverPairedWhenNoMacKnownAndNotReconnecting() {
        #expect(
            DisconnectedShellPolicy.state(
                hasKnownPairedMac: false,
                isReconnectingStoredMac: false,
                isRecoveringConnection: false
            ) == .neverPaired
        )
    }

    @Test func offlineWhenMacKnownAndNotReconnecting() {
        #expect(
            DisconnectedShellPolicy.state(
                hasKnownPairedMac: true,
                isReconnectingStoredMac: false,
                isRecoveringConnection: false
            ) == .offline
        )
    }

    @Test func reconnectingWhenStoredMacReconnectInFlight() {
        // An in-flight stored-Mac reconnect wins over the known-Mac offline state.
        #expect(
            DisconnectedShellPolicy.state(
                hasKnownPairedMac: true,
                isReconnectingStoredMac: true,
                isRecoveringConnection: false
            ) == .reconnecting
        )
    }

    @Test func reconnectingWhenRecoveryInFlight() {
        // A user-initiated / network recovery attempt also shows the reconnecting
        // state, even for a device that has no persisted hint yet.
        #expect(
            DisconnectedShellPolicy.state(
                hasKnownPairedMac: true,
                isReconnectingStoredMac: false,
                isRecoveringConnection: true
            ) == .reconnecting
        )
        #expect(
            DisconnectedShellPolicy.state(
                hasKnownPairedMac: false,
                isReconnectingStoredMac: false,
                isRecoveringConnection: true
            ) == .reconnecting
        )
    }

    @Test func inFlightAttemptOverridesEvenWithoutKnownMac() {
        #expect(
            DisconnectedShellPolicy.state(
                hasKnownPairedMac: false,
                isReconnectingStoredMac: true,
                isRecoveringConnection: false
            ) == .reconnecting
        )
    }
}
