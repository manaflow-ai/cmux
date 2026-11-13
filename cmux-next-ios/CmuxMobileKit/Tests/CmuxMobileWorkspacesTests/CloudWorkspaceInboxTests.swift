import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// Cloud machines on the Workspaces list: a running one's rows mix with the Macs' by recency;
/// every other state is one line that says what it means and offers the one thing to do.
@Suite struct CloudWorkspaceInboxTests {
    let mac = MacDevice(id: "m", name: "Studio", isOnline: true)

    func cloud(_ id: String, _ status: CloudMachineState.Status, note: String? = nil, pending: Bool = false) -> MacDevice {
        MacDevice(cloudMachine: id, name: id, state: CloudMachineState(status: status, note: note, pendingWorkspace: pending))
    }

    func ws(_ id: String, on macID: String, age: TimeInterval) -> Workspace {
        Workspace(id: id, macID: macID, title: id, directory: "~", tabs: [], lastActivityAt: Date(timeIntervalSince1970: 1000 - age))
    }

    @Test func runningCloudRowsMixWithTheMacsByRecency() {
        let inbox = WorkspaceInbox(scope: .all, macs: [mac, cloud("vm_run", .running)],
                                   workspaces: [ws("mac-old", on: "m", age: 30), ws("cloud-new", on: "vm_run", age: 0), ws("mac-mid", on: "m", age: 10)])
        #expect(inbox.recent.map(\.id) == ["cloud-new", "mac-mid", "mac-old"])
        #expect(inbox.folds.isEmpty)
        #expect(inbox.showsMacNames)
    }

    @Test func eachCloudStateIsALine() {
        let machines = [mac, cloud("vm_p", .paused), cloud("vm_s", .starting), cloud("vm_v", .provisioning, pending: true),
                        cloud("vm_f", .failed, note: "It didn't start."), cloud("vm_e", .running), cloud("vm_d", .deleting)]
        let inbox = WorkspaceInbox(scope: .all, macs: machines, workspaces: [ws("a", on: "m", age: 0), ws("kept", on: "vm_p", age: 99)])
        let reasons = Dictionary(uniqueKeysWithValues: inbox.folds.map { ($0.mac.id, $0.reason) })
        #expect(reasons["vm_p"] == .cloudPaused)
        #expect(reasons["vm_s"] == .cloudWaking)
        #expect(reasons["vm_v"] == .cloudWaking)
        #expect(reasons["vm_f"] == .cloudFailed("It didn't start."))
        #expect(reasons["vm_e"] == .cloudEmpty)
        #expect(reasons["vm_d"] == nil)
        // The paused machine's last-known workspace folds under its line, offline.
        #expect(inbox.folds.first { $0.mac.id == "vm_p" }?.workspaces.map(\.id) == ["kept"])
        #expect(inbox.status(ws("kept", on: "vm_p", age: 99)) == .offline)
        #expect(!inbox.recent.contains { $0.id == "kept" })
    }

    /// Just started: the machine says running, but this phone has not dialed it or its daemon has
    /// not listed anything yet. Its line keeps saying it is waking, never vanishing in between
    /// (live capture at 9e7c5fc6: no Cloud line for 4-7 s after "Waking up…").
    @Test func aRunningMachineWithNothingListedYetIsStillWaking() {
        // Dialing for the first time, or again after its link closed (an earlier answer is cached).
        for phase in [MacDataMachine.Phase.loading, .cached(.connecting)] {
            let inbox = WorkspaceInbox(scope: .all, macs: [mac, cloud("vm_r", .running)], workspaces: [ws("a", on: "m", age: 0)],
                                       context: .init(phases: ["m": .live, "vm_r": phase]))
            #expect(inbox.folds.first { $0.mac.id == "vm_r" }?.reason == .cloudWaking, "\(phase)")
        }
        // Not dialed (the link cap left it out, or its link closed after an empty answer): never
        // "Waking up…" for ever, and never no line at all; its line offers Connect.
        for phase in [MacDataMachine.Phase.idle, .cached(.idle)] {
            let inbox = WorkspaceInbox(scope: .all, macs: [mac, cloud("vm_r", .running)], workspaces: [ws("a", on: "m", age: 0)],
                                       context: .init(phases: ["m": .live, "vm_r": phase]))
            #expect(inbox.folds.first { $0.mac.id == "vm_r" }?.reason == .notConnected, "\(phase)")
        }
        // Its last dial failed (a first answer is cached, or none): the line says why, with Retry.
        for phase in [MacDataMachine.Phase.cached(.failed("no route")), .failed("no route")] {
            let inbox = WorkspaceInbox(scope: .all, macs: [mac, cloud("vm_r", .running)], workspaces: [ws("a", on: "m", age: 0)],
                                       context: .init(phases: ["m": .live, "vm_r": phase]))
            #expect(inbox.folds.first { $0.mac.id == "vm_r" }?.reason == .failed("no route"), "\(phase)")
        }
        // Once its daemon answers with nothing, it is the empty machine (New Workspace).
        let empty = WorkspaceInbox(scope: .all, macs: [mac, cloud("vm_r", .running)], workspaces: [],
                                   context: .init(phases: ["m": .live, "vm_r": .empty]))
        #expect(empty.folds.first { $0.mac.id == "vm_r" }?.reason == .cloudEmpty)
    }

    /// Asleep speaks of Macs: paused Cloud machines don't make "Your Macs are asleep" when a Mac is up,
    /// and a running one keeps it from showing.
    @Test func asleepCountsMacsOnly() {
        let sleeping = MacDevice(id: "m", name: "Studio", isOnline: false)
        let paused = WorkspaceInbox(scope: .all, macs: [sleeping, cloud("vm_p", .paused)], workspaces: [])
        #expect(paused.allAsleep)
        let running = WorkspaceInbox(scope: .all, macs: [sleeping, cloud("vm_r", .running)], workspaces: [])
        #expect(!running.allAsleep)
        let cloudOnly = WorkspaceInbox(scope: .all, macs: [cloud("vm_p", .paused)], workspaces: [])
        #expect(!cloudOnly.allAsleep)
        #expect(cloudOnly.folds.map(\.reason) == [.cloudPaused])
    }

    /// Filtered to a paused machine, its line stays (it carries Start) and its rows show.
    @Test func aFilteredPausedMachineKeepsItsLine() {
        let inbox = WorkspaceInbox(scope: .mac("vm_p"), macs: [mac, cloud("vm_p", .paused)], workspaces: [ws("kept", on: "vm_p", age: 0)])
        #expect(inbox.folds.map(\.reason) == [.cloudPaused])
        #expect(inbox.folds.first?.isForcedOpen == true)
        #expect(inbox.folds.first?.reason.isCloud == true)
    }

    /// Filtered to an empty running machine: the page's own empty state (New Workspace), no line.
    @Test func aFilteredEmptyMachineIsTheEmptyState() {
        let inbox = WorkspaceInbox(scope: .mac("vm_e"), macs: [mac, cloud("vm_e", .running)], workspaces: [])
        #expect(inbox.folds.isEmpty)
        #expect(inbox.isEmpty)
    }

    /// A search shows only machines with matching rows.
    @Test func aSearchDropsEmptyCloudLines() {
        let inbox = WorkspaceInbox(scope: .all, macs: [mac, cloud("vm_p", .paused), cloud("vm_e", .running)],
                                   workspaces: [ws("needle", on: "m", age: 0)], query: "needle")
        #expect(inbox.folds.isEmpty)
    }

    #if os(iOS)
    @MainActor @Test func theLineSaysWhatTheStateMeans() {
        let line = { (machine: MacDevice, reason: WorkspaceInbox.Fold.Reason) in
            WorkspacesList.cloudFoldSentence(WorkspaceInbox.Fold(mac: machine, reason: reason, workspaces: [], isForcedOpen: false))
        }
        #expect(line(cloud("Build", .paused), .cloudPaused) == "Build · Cloud · Paused")
        #expect(line(cloud("Build", .starting), .cloudWaking) == "Build · Cloud · Waking up…")
        #expect(line(cloud("Cloud Machine", .provisioning, pending: true), .cloudWaking) == "Starting Cloud Machine…")
        #expect(line(cloud("Build", .failed, note: "Out of capacity."), .cloudFailed("Out of capacity.")) == "Build · Cloud · Out of capacity.")
        #expect(line(cloud("Build", .running), .cloudEmpty) == "Build · Cloud · No workspaces")
    }
    #endif
}
