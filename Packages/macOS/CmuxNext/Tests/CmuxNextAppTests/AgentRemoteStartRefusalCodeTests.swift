@testable import CmuxNextApp
import Testing

/// The App's name for the folder-needed refusal code and the code CmuxNextDaemonService's
/// AgentRemoteStartRefusal uses stay the same string.
struct AgentRemoteStartRefusalCodeTests {
    @Test func theFolderNeededCodeIsTheRefusalsOwn() {
        #expect(AgentRemoteStartRefusal.folderNeeded(machine: "m").code == AgentRemoteStartRefusal.folderNeededCode)
        #expect(AgentRemoteStartRefusal.folderNeeded(machine: "m").userMessage.contains("Choose folder"))
    }
}
