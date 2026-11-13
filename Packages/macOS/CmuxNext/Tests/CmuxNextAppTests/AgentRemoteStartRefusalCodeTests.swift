@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The App's name for the folder-needed refusal code and the code CmuxNextDaemonService's
/// AgentRemoteStartRefusal uses stay the same string.
struct AgentRemoteStartRefusalCodeTests {
    @Test func theFolderNeededCodeIsTheRefusalsOwn() {
        #expect(AgentRemoteStartRefusal.folderNeeded(machine: "m").code == AgentRemoteStartRefusal.folderNeededCode)
        #expect(AgentRemoteStartRefusal.folderNeeded(machine: "m").userMessage.contains("Choose folder"))
    }

    /// A chat set up on the owner's model connection whose machine's daemon takes no credential is
    /// an older daemon's refusal: the start updates the machine and tries once more
    /// (``AgentRemoteStartCoordinator``), never starting on the machine's own route; each says why.
    @Test func aCredentialTheDaemonCannotTakeUpdatesTheMachine() {
        #expect(AgentRemoteStartRefusal.olderDaemonCodes.contains(AgentSessionAttachClient.credentialsUnsupported))
        let older = AgentRemoteStartRefusal(code: AgentSessionAttachClient.credentialsUnsupported, machine: "devbox")
        #expect(older.userMessage.contains("devbox") && older.userMessage.contains("Update cmux"))
        #expect(AgentRemoteStartRefusal.credentialMismatch(machine: "devbox").userMessage.contains("new chat"))
        #expect(!AgentRemoteStartRefusal.olderDaemonCodes.contains(AgentRemoteStartRefusal.credentialMismatchCode))
    }
}
