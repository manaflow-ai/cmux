import CmuxNextServer
@testable import CmuxNextAgentLanes
import CmuxNextSidebar
import Foundation
import Testing

/// The Hosts section is a transient projection of the Machines page rows. These tests keep its
/// identity, state words and click routing independent of the app composition root.
@MainActor
struct HostsSidebarTests {
    private static func machine(_ id: String, _ name: String, connected: Bool = true, connecting: Bool = false,
                                state: MachineServerState? = nil, kind: MachineKind = .ssh) -> MachineSectionRow {
        MachineSectionRow(id: id, name: name, isConnected: connected, isLocal: false, kind: kind,
                          isConnecting: connecting, serverState: state)
    }

    @Test func foldedAndExpandedRowsUseStableTransientIds() throws {
        let machines = [Self.machine("local", "This Mac", kind: .local), Self.machine("cloud", "Build VM", connected: false, state: .paused, kind: .cloud)]
        let hosts = HostsSidebar()
        hosts.bind(host: .init(rows: { machines }, add: {}, open: { _ in }))

        let expanded = hosts.rows()
        #expect(expanded.map { $0.item.id.rawValue } == ["client.hosts:header", "client.hosts:add", "client.hosts:row:local", "client.hosts:row:cloud"])
        #expect(expanded[0].info.title == "Hosts" && expanded[0].info.badge == 2)
        #expect(expanded[1].info.title == "Add Host…" && expanded[1].info.indent == 1)
        #expect(expanded[2].info.caption == "Connected" && expanded[3].info.caption == "Paused")
        #expect(expanded.dropFirst().allSatisfy { $0.after.last?.rawValue == "client.hosts:header" || $0.info.indent == 1 })
        #expect(hosts.activate(expanded[0].item.id))
        #expect(hosts.rows().map { $0.item.id.rawValue } == ["client.hosts:header"])
    }

    @Test func connectingAndOfflineStatesAreWordsAndRowsKeepDeviceSymbols() {
        let machines = [Self.machine("connecting", "Joining", connected: false, connecting: true),
                        Self.machine("offline", "Gone", connected: false),
                        Self.machine("failed", "Broken", connected: false, state: .failed, kind: .server)]
        let rows = HostsSidebar.rows(machines: machines, expanded: true)
        #expect(rows.dropFirst().map(\.info.caption) == ["Add Host…", "Connecting…", "Offline", "Failed"])
        #expect(rows.first { $0.item.id.rawValue.hasSuffix("connecting") }?.info.activity == .working)
        #expect(rows.first { $0.item.id.rawValue.hasSuffix("offline") }?.info.isMissing == true)
    }

    @Test func addAndHostClicksUseTheSharedMachineRows() throws {
        let machine = Self.machine("m1", "Desk", kind: .server)
        var added = false
        var opened: String?
        let hosts = HostsSidebar()
        hosts.bind(host: .init(rows: { [machine] }, add: { added = true }, open: { opened = $0.id }))
        let expanded = hosts.rows()
        _ = try #require(expanded.first)
        #expect(hosts.activate(expanded[1].item.id) && added)
        #expect(hosts.activate(expanded[2].item.id) && opened == "m1")
        #expect(!hosts.activate(LayoutItemID("client.other")))
    }
}
