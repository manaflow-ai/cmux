import Testing
@testable import CmuxNextRemoteView

/// The pane exists only in Debug builds (phase-1 trust gap). `swift test`
/// builds Debug, so this checks the Debug side; Release compiles the pane
/// out with `#if DEBUG`, which the CI Release compile exercises.
struct RemoteViewAvailabilityTests {
    @Test func debugBuildsExposeThePane() {
        #expect(RemoteViewAvailability().isAvailable)
    }

    @Test func connectingStatesShowTheDevelopmentOnlyNote() {
        let note = RemoteViewStrings.developmentOnly
        #expect(RemoteStateCard.spec(for: .connecting, host: "vm").note == note)
        #expect(RemoteStateCard.spec(for: .waitingForConsent, host: "vm").note == note)
        #expect(RemoteStateCard.spec(for: .ended(.connectionLost), host: "vm").note == nil)
    }
}
