import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Testing

/// The chat menu's length (Lawrence, 2026-10-01: long menus use submenus), counted where the
/// menu is built. Its catalog list has three Cloud rows (Move to Cloud, Bring Back Local, Move to
/// Another Machine) and the builder takes away the ones a chat does not offer
/// (`AgentTabs+Header`: ``CloudMove/hiddenMenuItems(_:)``, then
/// `contextMenuEntries(for: .agentChat, removing:)`), so no chat shows all three.
/// `ActionSurfaceParityTests.everyMenuKeepsAShortTopLevel` leaves this menu's count to this
/// suite. The hidden rows here come from that same function, for each kind of chat it tells apart.
@MainActor
@Suite struct ChatMenuLengthTests {
    /// 12 rows and the fork commands, as the catalog test had it for this menu.
    static let cap = 13
    static let machineHost = MachineRegistry.registryHostPrefix + "chat-menu-length"

    @Test func noKindOfChatHasAMenuLongerThanTheCap() throws {
        // A chat that a move from this Mac put on a machine is one with a ledger entry.
        let ledger = CloudMovedChats()
        ledger.record(.init(machineID: "vm", host: Self.machineHost, session: "s-moved", harness: "codex",
                            localRoot: "/local/project", localChat: "/local/project",
                            remoteFolder: "/home/dev/project", remoteChat: "/home/dev/project"))
        let before = CloudMovedChats.app
        CloudMovedChats.app = ledger
        defer { CloudMovedChats.app = before }

        let thisMac = AgentSessionRef.host(installID: "chat-menu-length")
        let kinds: [(name: String, record: AgentSessionRef?)] = [
            ("a chat on this Mac", AgentSessionRef(host: thisMac, session: "s-local", harness: "codex")),
            ("a new chat on this Mac, before its session", AgentSessionRef(host: thisMac, harness: "codex")),
            ("a chat that a move put on a machine", AgentSessionRef(host: Self.machineHost, session: "s-moved", harness: "codex")),
            ("a chat that started on a machine", AgentSessionRef(host: Self.machineHost, session: "s-started-there", harness: "codex")),
            ("a new chat on a machine, before its session", AgentSessionRef(host: Self.machineHost, harness: "codex")),
            ("a tab with no chat record", nil),
        ]
        let catalog = ContextMenuCatalog.shared.entries(for: .agentChat)
        let cloudRows: Set<ActionID> = [CloudMove.action, CloudBringBack.action, CloudBringBack.toMachine]
        #expect(cloudRows.isSubset(of: ContextMenuCatalog.shared.referencedIDs(catalog)), "the chat menu's catalog has the three Cloud rows")

        var mostCloudRows = 0
        for kind in kinds {
            let hidden = CloudMove.hiddenMenuItems(kind.record)
            let menu = ContextMenuCatalog.removing(hidden, from: catalog)
            let rows = menu.filter { if case .separator = $0 { false } else { true } }
            #expect(rows.count <= Self.cap, "\(kind.name): the chat menu has \(rows.count) top-level rows")
            let shown = cloudRows.intersection(ContextMenuCatalog.shared.referencedIDs(menu))
            #expect(shown != cloudRows, "\(kind.name) shows the three Cloud rows together")
            mostCloudRows = max(mostCloudRows, shown.count)
        }
        // The ledger arm is real: the moved chat is the one with Bring Back Local and Move to Another Machine.
        let moved = try #require(kinds[2].record)
        #expect(CloudMove.hiddenMenuItems(moved) == [CloudMove.action], "the moved chat does not offer its two rows")
        #expect(mostCloudRows == 2)
    }
}
