import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPages
@testable import CmuxNextServer
import CmuxNextSettings
import Foundation
import Testing

/// The right sidebar's Machines section rows as the app reads them (the layout, words and controls
/// are the page's: webviews/src/pages/machines, model.test.ts and machines-section.test.tsx).
@Suite struct MachineSectionLayoutTests {
    @Test func aRowsKindAndStateFollowItsLink() {
        #expect(MachineSectionRow(id: "local", name: "This Mac", isConnected: true, isLocal: true).kind == .local)
        #expect(MachineSectionRow(id: "x", name: "x", isConnected: false, isLocal: false).kind == .ssh)
        let connecting = MachineSectionRow(id: "c", name: "c", isConnected: false, isLocal: false, kind: .cloud, isConnecting: true)
        #expect(connecting.isConnecting)
        // A connected link is never "connecting", whatever the caller passed.
        let connected = MachineSectionRow(id: "c", name: "c", isConnected: true, isLocal: false, kind: .cloud, isConnecting: true)
        #expect(!connected.isConnecting)
    }

    /// A paused Cloud machine is not connecting (cloud dogfood: three paused machines spun forever): its
    /// row has no spinner even while its daemon retries the link. A resume keeps one; a failed or
    /// deleted machine has none; a connected link wins.
    @Test func aCloudMachinesServerStateReplacesTheConnectingSpinner() {
        func row(_ state: MachineServerState?, connected: Bool = false, connecting: Bool = true) -> MachineSectionRow {
            MachineSectionRow(id: "c", name: "c", isConnected: connected, isLocal: false, kind: .cloud, isConnecting: connecting,
                              serverState: state)
        }
        #expect(!row(.paused).isConnecting && row(.paused).serverState == .paused)
        #expect(row(.resuming, connecting: false).isConnecting)
        #expect(!row(.failed).isConnecting && !row(.deleted).isConnecting)
        let connected = row(.paused, connected: true)
        #expect(connected.serverState == nil && !connected.isConnecting)
        #expect(row(nil).isConnecting)
    }

    @Test func theFixtureHasEveryRemoteKindAndState() {
        let fixture = MachineSectionRow.fixtures
        #expect(Set(fixture.map(\.kind)) == [.cloud, .ssh, .server])
        #expect(fixture.contains { $0.isConnecting })
        #expect(fixture.contains { !$0.isConnected && !$0.isConnecting })
        #expect(fixture.contains { $0.serverState == .paused && !$0.isConnecting })
        #expect(Set(fixture.map(\.id)).count == fixture.count)
        #expect(!fixture.contains { $0.isLocal })
    }
}

/// The Machines section page's provider: the snapshot the page reads (the wire shape of
/// webviews/src/pages/machines/types.ts), its actions through the registry, the native menus, and no
/// stream events while the section is hidden.
@MainActor @Suite struct MachineSectionPageProviderTests {
    @MainActor final class Box {
        var rows: [MachineSectionRow] = [MachineSectionRow(id: "local", name: "This Mac", isConnected: true, isLocal: true)]
        var ran: [String] = []
        var presented: [(String, CGPoint)] = []
    }

    static func provider(_ box: Box, joined: JoinedMachineStore? = nil) -> MachineSectionPageProvider {
        MachineSectionPageProvider(dependencies: .init(
            rows: { box.rows }, style: { .grouped }, joined: { joined },
            newWorkspace: { box.ran.append("new:\($0)"); return true }, addMachine: { box.ran.append("add"); return true },
            present: { menu, point in box.presented.append((menu.items.first?.title ?? "", point)) },
            menu: { kind, row in
                let menu = NSMenu()
                menu.addItem(withTitle: "\(kind):\(row.id)", action: nil, keyEquivalent: "")
                return menu
            }))
    }

    static let context = PageCallContext(page: PageDescriptor.machines.id, userGesture: true, gestureEvent: 1)

    @Test func theSnapshotCarriesEachRowAndTheJoinedState() async throws {
        let box = Box()
        let machine = JoinedMachine(id: "m_1", name: "lane-vm-3", state: .online, platform: "linux", mintedBy: "you@example.com")
        box.rows.append(.joined(machine, health: nil))
        box.rows.append(MachineSectionRow(id: "c3", name: "night-batch", isConnected: false, isLocal: false, kind: .cloud,
                                          isConnecting: true, serverState: .paused, health: .warning, healthStep: .update))
        let store = JoinedMachineStore(service: { nil })
        store.openMenu = "m_1"
        let snapshot = try await Self.provider(box, joined: store).call(MachineSectionPageProvider.snapshotOp, params: .object([:]),
                                                                       context: Self.context)
        #expect(snapshot["style"]?.stringValue == "grouped")
        #expect(snapshot["openMenu"]?.stringValue == "m_1")
        guard case .array(let rows)? = snapshot["rows"] else { Issue.record("no rows"); return }
        #expect(rows.map { $0["id"]?.stringValue } == ["local", "joined:m_1", "c3"])
        #expect(rows[0]["kind"]?.stringValue == "local" && rows[0]["isLocal"]?.boolValue == true)
        #expect(rows[1]["joined"]?["mintedBy"]?.stringValue == "you@example.com")
        #expect(rows[1]["kind"]?.stringValue == "joined")
        #expect(rows[2]["serverState"]?.stringValue == "paused" && rows[2]["isConnecting"]?.boolValue == false)
        #expect(rows[2]["health"]?.stringValue == "warning" && rows[2]["healthStep"]?.stringValue == "update")
    }

    @Test func newWorkspaceAddMachineAndMenusRunThroughTheApp() async throws {
        let box = Box()
        let provider = Self.provider(box)
        _ = try await provider.call(MachineSectionPageProvider.newWorkspaceOp, params: ["machine": "local"], context: Self.context)
        _ = try await provider.call(MachineSectionPageProvider.addMachineOp, params: .object([:]), context: Self.context)
        #expect(box.ran == ["new:local", "add"])
        _ = try await provider.call(MachineSectionPageProvider.menuOp, params: ["row": "local", "menu": "row", "x": 10, "y": 20],
                                    context: Self.context)
        #expect(box.presented.map(\.0) == ["row:local"])
        #expect(box.presented.first?.1 == CGPoint(x: 10, y: 20))
        await #expect(throws: PageError.self) {
            try await provider.call(MachineSectionPageProvider.menuOp, params: ["row": "gone", "menu": "row"], context: Self.context)
        }
    }

    /// The row's native menu: New Workspace on This Machine from the registry, off while the link is down.
    @Test func aRowsMenuIsTheRegistrysNewWorkspaceRow() {
        let registry = ActionRegistry.standard()
        let down = MachineSectionRow(id: "h1", name: "build-host", isConnected: false, isLocal: false)
        let menu = MachineSectionHostView.menu("row", row: down, registry: registry)
        #expect(menu?.items.map(\.title) == [MachineSectionRow.newWorkspaceTitle])
        #expect(menu?.items.first?.isEnabled == false)
        #expect(MachineSectionHostView.menu("joined", row: down, registry: registry) == nil, "only a joined machine has the joined menu")
    }

    /// While the section is hidden the page hears nothing; showing it sends the newest snapshot once.
    @Test func aHiddenSectionsStreamSendsNothingUntilItShows() async throws {
        let box = Box()
        let store = JoinedMachineStore(service: { nil })
        let provider = Self.provider(box, joined: store)
        provider.setShown(true)
        var events: [JSONValue] = []
        let subscription = try await provider.subscribe(MachineSectionPageProvider.changesStream, filter: .object([:]),
                                                        context: Self.context) { events.append($0) }
        defer { subscription.cancel() }
        for _ in 0..<20 { await Task.yield() }
        #expect(events.isEmpty, "the first value is the one the page reads")
        provider.setShown(false)
        store.openMenu = "m_9"
        for _ in 0..<20 { await Task.yield() }
        #expect(events.isEmpty, "hidden: no event")
        provider.setShown(true)
        #expect(events.count == 1)
        #expect(events.last?["openMenu"]?.stringValue == "m_9")
        provider.setShown(true)
        #expect(events.count == 1, "nothing new: nothing sent")
    }
}
