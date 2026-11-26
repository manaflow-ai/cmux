import CmuxNextAgentPane
import CmuxNextServer
@testable import CmuxNextAgentLanes
import CmuxNextSidebar
import Foundation
import Observation
import Testing

/// The Hosts section is a transient projection of the Machines page rows. These tests keep its
/// identity, state words and click routing independent of the app composition root.
@MainActor
struct HostsSidebarTests {
    @Observable @MainActor
    fileprivate final class LabsFlag {
        var value = false
    }

    private actor PeerReads {
        var count = 0
        func read() -> [AcpmuxPeerList.Peer]? { count += 1; return nil }
        func value() -> Int { count }
    }

    private static func settle(_ done: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await done() { return true }
            await Task.yield()
        }
        return await done()
    }

    @Test func disablingWithoutRenderingStopsAging() async {
        let flag = LabsFlag()
        flag.value = true
        var stops = 0
        let hosts = HostsSidebar(host: .init(rows: { [] }, add: {}, openConnected: { _ in }, openJoined: { _ in },
            enabled: { flag.value }, refresh: {}, startAging: { _, _ in }, stopAging: { _ in stops += 1 }))
        defer { hosts.stop() }
        flag.value = false
        #expect(await Self.settle { stops == 1 })
    }

    private static func machine(_ id: String, _ name: String, connected: Bool = true, connecting: Bool = false,
                                failed: Bool = false, failure: String? = nil,
                                state: MachineServerState? = nil, kind: MachineKind = .ssh) -> MachineSectionRow {
        MachineSectionRow(id: id, name: name, isConnected: connected, isLocal: false, kind: kind,
                          isConnecting: connecting, failed: failed, failure: failure, serverState: state)
    }

    @Test func foldedAndExpandedRowsUseStableTransientIds() throws {
        let machines = [Self.machine("local", "This Mac", kind: .local), Self.machine("cloud", "Build VM", connected: false, state: .paused, kind: .cloud)]
        let hosts = HostsSidebar()
        hosts.bind(host: .init(rows: { machines }, add: {}, openConnected: { _ in }, openJoined: { _ in }))

        let expanded = hosts.rows()
        #expect(expanded.map { $0.item.id.rawValue } == ["client.hosts:header", "client.hosts:add", "client.hosts:row:local", "client.hosts:row:cloud"])
        #expect(expanded[0].info.title == "Hosts" && expanded[0].info.badge == 2)
        #expect(expanded[1].info.title == "Add Host…" && expanded[1].info.indent == 1)
        #expect(expanded[2].info.caption == "Connected" && expanded[3].info.caption == "Paused")
        #expect(expanded.dropFirst().allSatisfy { $0.after.last?.value == "client.hosts:header" || $0.info.indent == 1 })
        #expect(hosts.activate(expanded[0].item.id))
        #expect(hosts.rows().map { $0.item.id.rawValue } == ["client.hosts:header"])
    }

    @Test func connectingAndOfflineStatesAreWordsAndRowsKeepDeviceSymbols() {
        let machines = [Self.machine("connecting", "Joining", connected: false, connecting: true),
                        Self.machine("offline", "Gone", connected: false),
                        Self.machine("resuming", "Waking", connected: false, connecting: true, state: .resuming, kind: .cloud),
                        Self.machine("failed", "Broken", connected: false, state: .failed, kind: .server)]
        let rows = HostsSidebar.rows(machines: machines, expanded: true)
        #expect(rows.dropFirst().map(\.info.caption) == ["Add Host…", nil, "Offline", "Resuming…", "Failed"])
        #expect(rows.first { $0.item.id.rawValue.hasSuffix("connecting") }?.info.activity == .idle)
        #expect(rows.first { $0.item.id.rawValue.hasSuffix("connecting") }?.info.isMissing == false)
        #expect(rows.first { $0.item.id.rawValue.hasSuffix("offline") }?.info.isMissing == false)
    }

    /// Leo, 2026-11-24: "all the connecting... indicators and the graying out of workspaces, nah let's not do that.
    /// let's just keep optimistically connecting and reinforcing the connection and sync-ups can be satisfying
    /// instead of making the user think they're constsntly suspended in a state of connection limbo". A machine's row
    /// said "Connecting…" with a spinner once a launch connect or redial lasted 10 s. It now never does: no words, no
    /// spinner, not greyed, however long the connect lasts. A resume the person started still says "Resuming…".
    @Test func aConnectNeverSaysConnecting() async throws {
        let machines = [Self.machine("connecting", "Joining", connected: false, connecting: true),
                        Self.machine("resuming", "Waking", connected: false, connecting: true, state: .resuming, kind: .cloud)]
        let hosts = HostsSidebar(host: .init(rows: { machines }, add: {}, openConnected: { _ in }, openJoined: { _ in }))
        defer { hosts.stop() }
        for _ in 0..<3 {
            let rows = hosts.rows()
            let joining = try #require(rows.first { $0.item.id.rawValue.hasSuffix("connecting") })
            #expect(joining.info.caption == nil && joining.info.activity == .idle && !joining.info.isMissing)
            #expect(rows.first { $0.item.id.rawValue.hasSuffix("resuming") }?.info.caption == "Resuming…")
            #expect(rows.first?.info.activity == .working, "the header spins only for the resume the person started")
            try await Task.sleep(for: .milliseconds(20)) // wakeup-allow: proves no timer turns the row into "Connecting…"
        }
    }

    @Test func addAndHostClicksUseTheSharedMachineRows() throws {
        let machine = Self.machine("m1", "Desk", kind: .server)
        var added = false
        var opened: String?
        let hosts = HostsSidebar()
        hosts.bind(host: .init(rows: { [machine] }, add: { added = true }, openConnected: { opened = $0 }, openJoined: { _ in }))
        let expanded = hosts.rows()
        _ = try #require(expanded.first)
        #expect(hosts.activate(expanded[1].item.id) && added)
        #expect(hosts.activate(expanded[2].item.id) && opened == "m1")
        #expect(!hosts.activate(LayoutItemID("client.other")))
    }

    @Test func failedRowsStopSpinnerAndExposeTheSSHErrorTooltip() throws {
        let row = Self.machine("failed", "Broken", connected: false, connecting: true, failed: true, failure: "No route")
        let items = HostsSidebar.rows(machines: [row], expanded: true)
        let item = try #require(items.first { $0.item.id.rawValue.hasSuffix("failed") })
        #expect(item.info.caption == "Failed")
        #expect(item.info.activity == .idle)
        #expect(item.info.tooltip == "No route")
    }

    @Test func offlineAndConnectingRowsUseTheOfflineOpenCallback() throws {
        let machines = [Self.machine("offline", "Offline", connected: false),
                        Self.machine("connecting", "Connecting", connected: false, connecting: true)]
        var opened: [String] = []
        let hosts = HostsSidebar()
        hosts.bind(host: .init(rows: { machines }, add: {}, openConnected: { _ in }, openJoined: { _ in },
                               openOffline: { opened.append($0.id) }))
        let items = hosts.rows()
        let offline = try #require(items.first { $0.item.id.rawValue.hasSuffix("offline") })
        let connecting = try #require(items.first { $0.item.id.rawValue.hasSuffix("connecting") })
        #expect(hosts.activate(offline.item.id))
        #expect(hosts.activate(connecting.item.id))
        #expect(opened == ["offline", "connecting"])
    }

    @Test func meshOnlyJoinedMacsUseDialAndDisconnectedRowsStayClosed() {
        let joined = JoinedMachine(id: "m1", name: "Desk", state: .online, platform: "macos")
        let row = MachineSectionRow.joined(joined, health: nil)
        var connected: String?
        var dialed: String?
        let host = HostsSidebar.Host(rows: { [row] }, add: {}, openConnected: { connected = $0 }, openJoined: { dialed = $0.id })

        host.open(row)
        #expect(dialed == "m1")
        #expect(connected == nil)

        host.open(Self.machine("offline", "Offline", connected: false))
        #expect(dialed == "m1" && connected == nil)
    }

    @Test func meshOnlyJoinedLinuxDialsAndOfflineJoinedStaysClosed() {
        let joined = JoinedMachine(id: "linux-1", name: "Builder", state: .online, platform: "linux")
        let offline = JoinedMachine(id: "linux-2", name: "Asleep", state: .offline, platform: "linux")
        var connected: String?
        var dialed: [String] = []
        let host = HostsSidebar.Host(rows: { [] }, add: {}, openConnected: { connected = $0 }, openJoined: { dialed.append($0.id) })

        host.open(MachineSectionRow.joined(joined, health: nil))
        host.open(MachineSectionRow.joined(offline, health: nil))
        #expect(connected == nil)
        #expect(dialed == ["linux-1"])
    }

    @Test func boundHostRefreshesAndOwnsJoinedMachineAging() async {
        var refreshes = 0
        var starts = 0
        var stops = 0
        let host = HostsSidebar.Host(rows: { [] }, add: {}, openConnected: { _ in }, openJoined: { _ in },
                                     refresh: { refreshes += 1 },
                                     startAging: { _, _ in starts += 1 },
                                     stopAging: { _ in stops += 1 })
        let hosts = HostsSidebar(host: host)
        await Task.yield()
        #expect(refreshes == 1)
        #expect(starts == 1)

        hosts.bind(host: .init(rows: { [] }, add: {}, openConnected: { _ in }, openJoined: { _ in },
                               refresh: {}, startAging: { _, _ in }, stopAging: { _ in }))
        #expect(stops == 1)
    }

    @Test func disabledLabsSectionProjectsNoRowsOrActions() async {
        var added = false
        var enabled = false
        var refreshes = 0
        var agingStarts = 0
        let host = HostsSidebar.Host(rows: { [Self.machine("m1", "Desk")] }, add: { added = true },
                                     openConnected: { _ in }, openJoined: { _ in }, enabled: { enabled },
                                     refresh: { refreshes += 1 }, startAging: { _, _ in agingStarts += 1 }, stopAging: { _ in })
        let hosts = HostsSidebar(host: host)
        #expect(hosts.rows().isEmpty)
        #expect(!hosts.activate(LayoutItemID("client.hosts:add")))
        #expect(!added)
        #expect(refreshes == 0 && agingStarts == 0)
        enabled = true
        _ = hosts.rows()
        await Task.yield()
        #expect(refreshes == 1 && agingStarts == 1)
    }

    @Test func disabledLabsNeverBindsRemoteAndStopPreventsARebind() async {
        let flag = LabsFlag()
        let reads = PeerReads()
        let host = HostsSidebar.Host(rows: { [] }, add: {}, openConnected: { _ in }, openJoined: { _ in },
                                     enabled: { flag.value })
        let remoteHost = RemoteMachinesSidebar.Host(
            peers: { await reads.read() },
            older: { _, _ in nil }, displayName: { _ in nil }, open: { _ in })
        let sections = SidebarMachineSections()
        sections.bind(host: host, visible: { true }, socketPath: nil, displayName: { _ in nil }, open: { _ in },
                      remoteHost: remoteHost)
        for _ in 0..<3 { await Task.yield() }
        #expect(await reads.value() == 0)

        flag.value = true
        #expect(await Self.settle { await reads.value() > 0 })

        flag.value = false
        for _ in 0..<3 { await Task.yield() }
        let readsAfterDisable = await reads.value()
        sections.peerStateChanged(peer: "remote", state: "connected")
        for _ in 0..<3 { await Task.yield() }
        #expect(await reads.value() == readsAfterDisable)

        sections.stop()
        flag.value = true
        for _ in 0..<3 { await Task.yield() }
        #expect(await reads.value() == readsAfterDisable)
    }

    @Test func stopCancelsARefreshQueuedByBind() async {
        var refreshes = 0
        var agingStarts = 0
        var agingStops = 0
        let hosts = HostsSidebar()
        hosts.bind(host: .init(rows: { [] }, add: {}, openConnected: { _ in }, openJoined: { _ in },
                               refresh: { refreshes += 1 },
                               startAging: { _, _ in agingStarts += 1 }, stopAging: { _ in agingStops += 1 }))
        hosts.stop()
        for _ in 0..<3 { await Task.yield() }
        #expect(refreshes == 0)
        #expect(agingStarts == 1 && agingStops == 1)
        #expect(hosts.rows().isEmpty)
    }
}
