@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// P-AUSTIN B7a, reviews 3 and 4: what `SessionRegistrar` watches and when it sends. A home daemon
/// restart must change the observation key (so the registrar syncs and sends with the new epoch),
/// the key must not depend on the capability list (it was the whole identity as a string, rebuilt on
/// the main actor at each check), and nothing is sent while home is not connected.
@MainActor
@Suite struct SessionRegistrarWiringTests {
    private func identity(pid: Int32, generation: DaemonGeneration, capabilities: [String]) -> DaemonIdentity {
        DaemonIdentity(capabilities: capabilities, session: "main", pid: pid, registryID: "reg-1", generation: generation)
    }

    @Test func aRestartChangesTheKeyAndTheCapabilityListDoesNot() {
        let before = identity(pid: 100, generation: "gen-1", capabilities: ["profiles-v1"])
        let more = identity(pid: 100, generation: "gen-1", capabilities: ["profiles-v1", "window-records-v1"])
        let restarted = identity(pid: 200, generation: "gen-2", capabilities: ["profiles-v1"])
        let key = SessionRegistrar.homeKey(.connected(before), epoch: 1)
        #expect(key != SessionRegistrar.homeKey(.connected(restarted), epoch: 1), "a restarted home daemon does not change the key")
        #expect(key == SessionRegistrar.homeKey(.connected(more), epoch: 1), "the key depends on the capability list")
        #expect(!key.contains("profiles-v1"), "the key holds the identity's capabilities: \(key)")
        #expect(key != SessionRegistrar.homeKey(.connecting, epoch: 1))
        #expect(SessionRegistrar.homeKey(.disconnected("a"), epoch: 1) == SessionRegistrar.homeKey(.disconnected("b"), epoch: 1),
                "the key changes with each disconnect message")
    }

    @Test func nothingIsSentWhileHomeIsNotConnected() {
        #expect(SessionRegistrar.canRegister(.connected(identity(pid: 1, generation: "g", capabilities: []))))
        #expect(!SessionRegistrar.canRegister(.connecting))
        #expect(!SessionRegistrar.canRegister(.disconnected("down")))
        #expect(!SessionRegistrar.canRegister(.failed("refused")))
    }

    /// Review 6: a disconnect and a reconnect to the same daemon process can both land before the
    /// observation checks its key once; the connection epoch still changes, so the key must too, or a
    /// record waiting for an event after its retries is not sent again.
    @Test func aReconnectToTheSameDaemonProcessChangesTheKey() {
        let same = identity(pid: 100, generation: "gen-1", capabilities: ["profiles-v1"])
        #expect(SessionRegistrar.homeKey(.connected(same), epoch: 1) != SessionRegistrar.homeKey(.connected(same), epoch: 3),
                "a reconnect to the same daemon process does not change the key")
    }
}
