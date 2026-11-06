import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextDaemon
import Foundation
import Testing

/// The new workspace create path's decisions, moved out of `WorkspaceSpawner` into `WorkspaceSpawn` with the same
/// outputs: the start folder, the first terminal's environment, and which press takes the reserved next Cmd-N workspace.
@MainActor struct WorkspaceSpawnCreatePathTests {
    /// Only a plain Cmd-N (the New Tab page, nothing of its own) takes the reserved workspace; the reservation's folder
    /// is the one a press with no folder of its own gets.
    @Test func onlyAPlainNewTabPageTakesTheReservation() {
        var spawn = WorkspaceSpawn(newTabPage: true)
        #expect(spawn.isPlainNewTabPage)
        #expect(spawn.startFolder(roomFolder: "", local: true, daemonDefault: "/home") == "/home")
        #expect(spawn.startFolder(roomFolder: "/room", local: true, daemonDefault: "/home") == "/room")
        #expect(spawn.startFolder(roomFolder: "/room", local: false, daemonDefault: nil) == nil)
        spawn.inheritedCwd = "/work"
        #expect(spawn.isPlainNewTabPage, "an inherited folder is the press's, given to the page at the key")
        #expect(spawn.startFolder(roomFolder: nil, local: true, daemonDefault: "/home") == "/work")
        let changes: [(inout WorkspaceSpawn) -> Void] = [{ $0.cwd = "/x" }, { $0.command = "ls" }, { $0.firstSession = "s" },
                                                         { $0.key = WorkspaceKey.generate() }, { $0.browserProfile = "p" },
                                                         { $0.firstChat = AgentPaneSeed(cwd: nil) }]
        for change in changes {
            var other = WorkspaceSpawn(newTabPage: true)
            change(&other)
            #expect(!other.isPlainNewTabPage)
        }
        #expect(!WorkspaceSpawn().isPlainNewTabPage)
    }

    /// Later wins: the app's identity, then the room's defaults, then the caller's, then the placement keys.
    @Test func theTerminalEnvironmentMergesInOrder() {
        var spawn = WorkspaceSpawn()
        spawn.env = ["A": "caller", "C": "caller"]
        let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000009"), terminal = TerminalID.generate()
        let vars = spawn.terminalEnvironment(app: ["A": "app", "B": "app", "D": "app"], room: ["B": "room", "C": "room"], workspace: key, terminal: terminal)
        #expect(vars["A"] == "caller")
        #expect(vars["B"] == "room")
        #expect(vars["C"] == "caller")
        #expect(vars["D"] == "app")
        for (name, value) in DaemonConnection.placementEnvironment(workspace: key, terminal: terminal) { #expect(vars[name] == value) }
        #expect(WorkspaceSpawn().terminalEnvironment(app: [:], room: nil, workspace: key, terminal: terminal)
                == DaemonConnection.placementEnvironment(workspace: key, terminal: terminal))
    }
}
