@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Testing

/// Group commands go to the daemon that owns the group (OWNERSHIP-PRINCIPLES):
/// TabGroupMoves used the local daemon for every group, so a tab group in a
/// remote machine's workspace was sent to the wrong daemon.
@MainActor
struct GroupOwnershipTests {
    /// A workspace with one pane holding tab group `tabGroup` and one screen
    /// group `screenGroup`.
    static func tree(_ key: String, tabGroup: String, screenGroup: String) throws -> DaemonTree {
        let json = #"""
        {"workspace_revision":1,"generation":"GEN","registry_id":"r","workspaces":[{"id":1,"key":"\#(key)","name":"w",
         "screen_groups":[{"id":"\#(screenGroup)","name":"S","color":"green","collapsed":false,"start":0,"count":1,"screens":[4]}],
         "screens":[{"id":4,"active":true,"active_pane":3,"layout":{"pane":3,"type":"leaf"},
          "panes":[{"id":3,"active_tab":0,"tabs":[],
           "tab_groups":[{"id":"\#(tabGroup)","name":"T","color":"red","collapsed":false,"start":0,"count":0,"surfaces":[]}]}]}]}]}
        """#
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    static func machines() throws -> (MachineRegistry, DaemonService) {
        let machines = MachineRegistry(local: DaemonService())
        let host = try SSHHost(destination: SSHDestination(parsing: "dev@build-box.local"), session: "main")
        let paths = SSHPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("groups-\(UUID().uuidString)"))
        let remote = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"), paths: paths, environment: { [:] })
        machines.add(remote)
        machines.local.store.apply(snapshot: try tree("0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c01", tabGroup: "tg_here", screenGroup: "sgrp_here"))
        remote.daemon.store.apply(snapshot: try tree("1b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c02", tabGroup: "tg_there", screenGroup: "sgrp_there"))
        return (machines, remote.daemon)
    }

    @Test func aTabGroupIsOwnedByTheDaemonThatHoldsIt() throws {
        let (machines, remote) = try Self.machines()
        #expect(machines.local.store.workspaces.first?.screens.first?.panes.first?.tabGroups.first?.id == TabGroupID(rawValue: "tg_here"))
        #expect(GroupOwnership.daemon(holdingTabGroup: TabGroupID(rawValue: "tg_here"), machines: machines) === machines.local)
        #expect(GroupOwnership.daemon(holdingTabGroup: TabGroupID(rawValue: "tg_there"), machines: machines) === remote,
                "a remote workspace's group goes to the remote daemon")
        #expect(GroupOwnership.daemon(holdingTabGroup: TabGroupID(rawValue: "tg_gone"), machines: machines) == nil,
                "a group no daemon holds has no owner (the command is refused)")
    }

    @Test func aScreenGroupIsOwnedByTheDaemonThatHoldsIt() throws {
        let (machines, remote) = try Self.machines()
        #expect(GroupOwnership.daemon(holdingScreenGroup: ScreenGroupID(rawValue: "sgrp_here"), machines: machines) === machines.local)
        #expect(GroupOwnership.daemon(holdingScreenGroup: ScreenGroupID(rawValue: "sgrp_there"), machines: machines) === remote)
        #expect(GroupOwnership.daemon(holdingScreenGroup: ScreenGroupID(rawValue: "sgrp_gone"), machines: machines) == nil)
    }

    @Test func thePaneHoldingAGroupComesWithItsDaemon() throws {
        let (machines, remote) = try Self.machines()
        let found = try #require(GroupOwnership.pane(holdingTabGroup: TabGroupID(rawValue: "tg_there"), machines: machines))
        #expect(found.daemon === remote)
        #expect(found.pane === remote.store.workspaces.first?.screens.first?.panes.first)
    }

    /// The check every whole-group move and every add-to-group runs
    /// (TabGroupMoves.owner, tabGroup.moveToWorkspace, tabGroup.addTab):
    /// the target must be on the group's own machine.
    @Test func aTargetOnAnotherMachineIsRefused() throws {
        let (machines, remote) = try Self.machines()
        let here = TabGroupID(rawValue: "tg_here"), there = TabGroupID(rawValue: "tg_there")
        #expect(GroupOwnership.owner(ofTabGroup: here, sameMachineAs: machines.local, machines: machines) === machines.local)
        #expect(GroupOwnership.owner(ofTabGroup: there, sameMachineAs: remote, machines: machines) === remote)
        #expect(GroupOwnership.owner(ofTabGroup: there, sameMachineAs: machines.local, machines: machines) == nil,
                "a remote group never takes a local target")
        #expect(GroupOwnership.owner(ofTabGroup: here, sameMachineAs: remote, machines: machines) == nil)
    }

    @Test func screenGroupTargetsResolveOnTheirOwnMachine() throws {
        let (machines, remote) = try Self.machines()
        let found = try #require(GroupOwnership.screenGroup(ScreenGroupID(rawValue: "sgrp_there"), machines: machines))
        #expect(found.daemon === remote)
        #expect(found.group.name == "S")
        #expect(GroupOwnership.daemon(holdingScreenGroup: ScreenGroupID(rawValue: "sgrp_there"), in: machines.daemons) === remote)
    }
}
