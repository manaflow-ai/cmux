import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextBridge
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

    /// `WorkspaceSpawner.shown`'s guard, moved with the same answers.
    @Test func whichCreatesShowBeforeTheDaemon() {
        #expect(WorkspaceSpawn(newTabPage: true).showsBeforeDaemon(local: false))
        var chat = WorkspaceSpawn(); chat.firstChat = AgentPaneSeed(cwd: nil)
        #expect(chat.showsBeforeDaemon(local: false))
        var session = WorkspaceSpawn(); session.firstSession = "s"
        #expect(session.showsBeforeDaemon(local: true))
        #expect(!WorkspaceSpawn().showsBeforeDaemon(local: true), "a terminal waits for the daemon")
        var command = WorkspaceSpawn(newTabPage: true); command.command = "ls"
        #expect(!command.showsBeforeDaemon(local: true))
        var profile = WorkspaceSpawn(newTabPage: true); profile.browserProfile = "p"
        #expect(!profile.showsBeforeDaemon(local: true))
        let folder = WorkspaceSpawn(cwd: "/x", newTabPage: true)
        #expect(folder.showsBeforeDaemon(local: true))
        #expect(!folder.showsBeforeDaemon(local: false), "a folder of its own only on this Mac")
    }

    /// `WorkspaceSpawner.start`'s row rule, moved with the same answers.
    @Test func theRowRuleKeepsTheCurrentAnchorOnlyWhenPlacedFromIt() {
        let top = NewWorkspaceDefaultSlot(placement: .top, current: "w1"), after = NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "w1")
        let plain = WorkspaceSpawn(newTabPage: true)
        #expect(plain.placement(setting: top).row == top && plain.placement(setting: top).rule == top)
        var notFromCurrent = plain; notFromCurrent.placesFromCurrent = false
        #expect(notFromCurrent.placement(setting: top).row?.current == nil)
        #expect(notFromCurrent.placement(setting: after).row?.current == "w1", "afterCurrent always places after it")
        var notBySetting = plain; notBySetting.placesBySetting = false
        #expect(notBySetting.placement(setting: top).row?.current == nil)
        #expect(notBySetting.placement(setting: top).rule == nil, "only a create placed by the setting gets a rule")
    }

    /// A create with a slot of its own (New Workspace Below) shows no default row, and keeps the rule as the fallback
    /// for a slot whose anchor closes during the create, never the daemon's place (Leo 2026-11-06).
    @Test func aCreateWithItsOwnSlotKeepsTheRuleOnlyAsItsFallback() {
        let after = NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "w1")
        var below = WorkspaceSpawn(newTabPage: true); below.slot = .below("w2")
        #expect(below.placement(setting: after).row == nil)
        #expect(below.placement(setting: after).rule == after)
    }

    /// `WorkspaceSpawner.create`'s first terminal options, moved with the same answers.
    @Test func theFirstTerminalStartsWithTheRoomOnlyOnThisMac() {
        var spawn = WorkspaceSpawn(); spawn.keep = true; spawn.inheritedCwd = "/work"
        let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-00000000000a"), terminal = TerminalID.generate()
        let room = ProfileDefaults(cwd: "/room", env: ["R": "room"])
        let local = spawn.terminalStart(app: ["A": "app"], room: room, local: true, daemonDefault: "/home", workspace: key, terminal: terminal, sendsEnv: true, reaps: true)
        #expect(local.cwd == "/room" && local.keep == true)
        #expect(local.env == spawn.terminalEnvironment(app: ["A": "app"], room: ["R": "room"], workspace: key, terminal: terminal))
        let remote = spawn.terminalStart(app: [:], room: room, local: false, daemonDefault: nil, workspace: key, terminal: terminal, sendsEnv: true, reaps: false)
        #expect(remote.cwd == nil && remote.keep == nil, "another machine: no room, no inherited folder; keep only where the daemon reaps")
        #expect(remote.env?["R"] == nil)
        #expect(spawn.terminalStart(app: [:], room: nil, local: true, daemonDefault: "/home", workspace: key, terminal: terminal, sendsEnv: false, reaps: true).env == nil)
        #expect(WorkspaceSpawn().terminalStart(app: [:], room: nil, local: true, daemonDefault: "/home", workspace: key, terminal: terminal, sendsEnv: true, reaps: true).keep == nil)
    }

    @Test func onlyACreateIntoAWindowNamesItsRow() {
        #expect(WorkspaceSpawn().rowName(inWindow: true) { "3" } == "3")
        #expect(WorkspaceSpawn().rowName(inWindow: false) { "3" } == nil)
        #expect(WorkspaceSpawn(name: "mine").rowName(inWindow: false) { "3" } == "mine")
    }

    /// `WindowController.isWaiting(for:)`, moved with the same answers.
    @Test func aWindowWaitsForACloudMachineOnlyWhileItLoads() {
        #expect(!CloudWorkspaceWait(signedIn: false, machinesLoaded: false, machineLive: true, mirrored: false).waits)
        #expect(CloudWorkspaceWait(signedIn: true, machinesLoaded: false, machineLive: nil, mirrored: false).waits)
        #expect(!CloudWorkspaceWait(signedIn: true, machinesLoaded: true, machineLive: nil, mirrored: false).waits)
        #expect(CloudWorkspaceWait(signedIn: true, machinesLoaded: true, machineLive: true, mirrored: false).waits)
        #expect(!CloudWorkspaceWait(signedIn: true, machinesLoaded: true, machineLive: true, mirrored: true).waits)
        #expect(!CloudWorkspaceWait(signedIn: true, machinesLoaded: true, machineLive: false, mirrored: false).waits)
    }
}
