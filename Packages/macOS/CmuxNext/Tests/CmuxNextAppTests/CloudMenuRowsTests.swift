import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The chat and tab menus have three Cloud rows in the catalog (Move to Cloud, Bring Back Local,
/// Move to Another Machine) and no chat shows all three: the rows the menus are built without
/// (``CloudMove/hiddenMenuItems(_:)``) always hold Move to Cloud, or the other two. The menu
/// length cap counts on it (`ActionSurfaceParityTests.rowsNeverShownTogether`): a change that
/// shows the three together fails here, and then the cap needs a folder for them.
@MainActor
@Suite struct CloudMenuRowsTests {
    @Test func noChatShowsAllThreeCloudRows() {
        let onThisMac = AgentSessionRef(host: AgentSessionRef.host(installID: "cloud-menu-rows"), session: "s-local", harness: "codex")
        let onAMachine = AgentSessionRef(host: MachineRegistry.registryHostPrefix + "cloud-menu-rows", session: "s-machine", harness: "codex")
        let away: Set<ActionID> = [CloudBringBack.action, CloudBringBack.toMachine]

        #expect(CloudMove.hiddenMenuItems(onThisMac).isSuperset(of: away), "a chat on this Mac shows a row that moves it off a machine")
        #expect(!CloudMove.hiddenMenuItems(onThisMac).contains(CloudMove.action), "a chat on this Mac has no Move to Cloud")
        // Whatever the moved-chats ledger says of it, a chat on a machine never offers Move to Cloud.
        #expect(CloudMove.hiddenMenuItems(onAMachine).contains(CloudMove.action), "a chat on a machine shows Move to Cloud")
        #expect(CloudMove.hiddenMenuItems(AgentSessionRef?.none) == away.union([CloudMove.action]), "a tab that is no chat shows a Cloud row")
    }
}
