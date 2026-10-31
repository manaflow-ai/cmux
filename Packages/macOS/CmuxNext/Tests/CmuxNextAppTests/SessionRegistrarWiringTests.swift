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
        let key = SessionRegistrar.homeKey(.connected(before))
        #expect(key != SessionRegistrar.homeKey(.connected(restarted)), "a restarted home daemon does not change the key")
        #expect(key == SessionRegistrar.homeKey(.connected(more)), "the key depends on the capability list")
        #expect(!key.contains("profiles-v1"), "the key holds the identity's capabilities: \(key)")
        #expect(key != SessionRegistrar.homeKey(.connecting))
        #expect(SessionRegistrar.homeKey(.disconnected("a")) == SessionRegistrar.homeKey(.disconnected("b")),
                "the key changes with each disconnect message")
    }

    @Test func nothingIsSentWhileHomeIsNotConnected() {
        #expect(SessionRegistrar.canRegister(.connected(identity(pid: 1, generation: "g", capabilities: []))))
        #expect(!SessionRegistrar.canRegister(.connecting))
        #expect(!SessionRegistrar.canRegister(.disconnected("down")))
        #expect(!SessionRegistrar.canRegister(.failed("refused")))
    }
}
