import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing

/// A workspace switch asks for a save of the window records (`WindowRecordSaver.stateDidChange`) and, 500 ms later, a
/// write of the launch record. Both are built on the main thread. A save walked the window's whole workspace list
/// (its keys, the machine of each, the set its other fields were checked against) and every machine's workspace
/// list (the prune's live set); the launch record read every sidebar row again. So a switch's main-thread work grew
/// with the workspace count: 81 ms at few workspaces, 118 ms at about 213 and 269 ms at four times that
/// (workspace-switch p95, `cmux perf profile --probe`, cmux#49027).
/// Each test counts the walks the work after a switch makes, at 10 and 1000 workspaces: none, at either size.
@MainActor @Suite(.serialized)
struct SwitchSaveCostTests {
    /// One switch to `key` and the turns it starts.
    private func switchTo(_ key: String, in bench: SpaceSwitchBench) {
        bench.services.windows.select(key, in: bench.state)
        bench.controller.showWorkspace(requested: bench.state.workspaceID)
        bench.drain()
    }

    @Test(arguments: [10, 1000])
    func theSaveAfterASwitchWalksNoWorkspaceList(_ total: Int) async throws {
        let bench = try await SpaceSwitchBench(total: total, spaces: 1, registered: true)
        defer { bench.close() }
        let saver = bench.services.windows.recordSaver
        _ = saver.currentRecords()
        let before = saver.memberships.builds
        for round in 0..<6 {
            let key = "k\((round * 7 + 3) % total)"
            switchTo(key, in: bench)
            let record = try #require(saver.currentRecords().first)
            #expect(record.workspaceKey?.rawValue == key, "the record of switch \(round) names the workspace the window shows")
            #expect(record.workspaceKeys.count == total, "the record of switch \(round) lists every workspace of the window")
        }
        let builds = saver.memberships.builds - before
        print("SWITCH-SAVE-COST n=\(total) membership_builds=\(builds)")
        #expect(builds == 0, "6 switches at \(total) workspaces walked the window's workspace list \(builds) times")
    }

    @Test(arguments: [10, 1000])
    func theLaunchRecordAfterASwitchReadsNoSidebarRow(_ total: Int) async throws {
        let bench = try await SpaceSwitchBench(total: total, spaces: 1, registered: true)
        defer { bench.close() }
        let saver = bench.services.windows.recordSaver
        _ = bench.services.launchRecordSnapshot(images: [:], socketPath: "")
        let before = saver.launchRows.builds
        for round in 0..<6 {
            let key = "k\((round * 7 + 3) % total)"
            switchTo(key, in: bench)
            let snapshot = bench.services.launchRecordSnapshot(images: [:], socketPath: "")
            let rows = Set(snapshot.sidebarRows.map(\.id))
            #expect(!rows.contains(key), "the launch record of switch \(round) lists the shown workspace as a sidebar row")
            #expect(rows.count == snapshot.sidebarRows.count, "the launch record of switch \(round) lists a row twice")
        }
        let builds = saver.launchRows.builds - before
        print("SWITCH-SAVE-COST n=\(total) launch_row_builds=\(builds)")
        #expect(builds == 0, "6 launch records after switches at \(total) workspaces read every sidebar row \(builds) times")
    }

    /// The kept `WindowListMembership` is built again when the window's list, its guests or the machines map change.
    @Test func theMembershipFollowsTheWindowsList() {
        var window = WindowRegistry.Window(id: "w", workspaceIDs: ["a", "b"])
        var machines = ["b": "cloud-1"]
        var kept = WindowListMembership(window: window, machines: machines, localID: "local", key: WorkspaceKey.init(rawValue:))
        #expect(kept.ownedKeys.map(\.rawValue) == ["a", "b"])
        #expect(kept.workspaceMachines == ["b": "cloud-1"])
        let hit1 = kept.matches(window, machines: machines)
        #expect(hit1)
        window.workspaceIDs.append("c")
        let hit2 = kept.matches(window, machines: machines)
        #expect(!hit2, "a workspace joined the window")
        kept = WindowListMembership(window: window, machines: machines, localID: "local", key: WorkspaceKey.init(rawValue:))
        window.guests = ["c"]
        let hit3 = kept.matches(window, machines: machines)
        #expect(!hit3, "a workspace became a guest")
        kept = WindowListMembership(window: window, machines: machines, localID: "local", key: WorkspaceKey.init(rawValue:))
        #expect(kept.ownedKeys.map(\.rawValue) == ["a", "b"], "a guest is its owner's to save")
        machines["a"] = "cloud-2"
        let hit4 = kept.matches(window, machines: machines)
        #expect(!hit4, "a workspace was seen on another machine")
    }
}
