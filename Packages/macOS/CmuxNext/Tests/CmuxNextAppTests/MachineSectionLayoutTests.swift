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
    /// A row carries the SF Symbol its daemon named for the device (cmux-device-kind) to the page, and
    /// sends none before the daemon said. A Cloud machine stays the cloud, whatever its VM reports.
    @Test func aRowSendsItsDeviceSymbol() {
        let silent = MachineSectionRow(id: "m", name: "build-mini", isConnected: true, isLocal: false)
        #expect(MachineSectionPageProvider.json(silent)["symbol"] == nil)
        let mini = MachineSectionRow(id: "m", name: "build-mini", isConnected: true, isLocal: false, symbol: "macmini")
        #expect(MachineSectionPageProvider.json(mini)["symbol"] == .string("macmini"))
        let vm = MachineSectionRow(id: "c", name: "vm", isConnected: true, isLocal: false, kind: .cloud, symbol: "server.rack")
        #expect(MachineSectionPageProvider.json(vm)["symbol"] == nil)
    }

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
        var answers: [JoinedDialAnswer] = []
        var asked: [String] = []
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
            }, openJoined: { _ in .unavailable("test") }))
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
        let ids = rows.map { $0["id"]?.stringValue }
        #expect(ids == ["local", "joined:m_1", "c3"])
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

    /// Page script with no click or key behind it runs nothing: New Workspace, Add Machine and the menus
    /// need the person's own gesture.
    @Test func actionsWithoutAPersonsGestureAreRefused() async throws {
        let box = Box()
        let provider = Self.provider(box)
        let scripted = PageCallContext(page: PageDescriptor.machines.id, userGesture: false, gestureEvent: nil)
        for (op, params) in [(MachineSectionPageProvider.newWorkspaceOp, ["machine": "local"] as JSONValue),
                             (MachineSectionPageProvider.addMachineOp, .object([:])),
                             (MachineSectionPageProvider.menuOp, ["row": "local", "menu": "row"] as JSONValue)] {
            await #expect(throws: PageError.self) { try await provider.call(op, params: params, context: scripted) }
        }
        #expect(box.ran.isEmpty)
        #expect(box.presented.isEmpty)
    }

    /// New Workspace runs only on a machine the section shows and that is connected; any other id (a fleet
    /// daemon the rows leave out, a link that is down) is refused even with the person's click.
    @Test func newWorkspaceRunsOnlyOnAConnectedRowOfTheSection() async throws {
        let box = Box()
        box.rows.append(MachineSectionRow(id: "down", name: "down", isConnected: false, isLocal: false))
        let provider = Self.provider(box)
        for id in ["fleet-lane-7", "down", ""] {
            await #expect(throws: PageError.self) {
                try await provider.call(MachineSectionPageProvider.newWorkspaceOp, params: ["machine": .string(id)], context: Self.context)
            }
        }
        #expect(box.ran.isEmpty)
        _ = try await provider.call(MachineSectionPageProvider.newWorkspaceOp, params: ["machine": "local"], context: Self.context)
        #expect(box.ran == ["new:local"])
    }

    /// A menu opens only on a row the section shows, and only a menu that row has, even with the person's
    /// click: a fleet daemon the rows leave out, an unknown menu, or a joined menu on a machine that is not
    /// joined present nothing.
    @Test func aMenuOpensOnlyOnAShownRowWithThatMenu() async throws {
        let box = Box()
        let machine = JoinedMachine(id: "m_1", name: "lane-vm-3", state: .online, platform: "linux", mintedBy: nil)
        box.rows.append(.joined(machine, health: nil))
        let provider = Self.provider(box)
        let refused: [JSONValue] = [["row": "fleet-lane-7", "menu": "row"], ["row": "local", "menu": "joined"],
                                    ["row": "local", "menu": "revoke"], ["menu": "row"]]
        for params in refused {
            await #expect(throws: PageError.self) {
                try await provider.call(MachineSectionPageProvider.menuOp, params: params, context: Self.context)
            }
        }
        #expect(box.presented.isEmpty)
        _ = try await provider.call(MachineSectionPageProvider.menuOp, params: ["row": "joined:m_1", "menu": "joined"], context: Self.context)
        let titles = box.presented.map(\.0)
        #expect(titles == ["joined:joined:m_1"])
    }

    /// Remove runs only on the person's click, on a joined row the section shows: never page script
    /// alone, a fleet daemon the rows leave out, or a machine that is not joined. On a joined row it
    /// runs the store's Remove on that row's machine.
    @Test func removeRunsOnlyOnAShownJoinedRowWithAClick() async throws {
        let box = Box()
        box.rows.append(.joined(JoinedMachine(id: "m_1", name: "lane-vm-3", state: .online, platform: "linux", mintedBy: nil), health: nil))
        let fake = JoinedMachineRowsTests.Fake()
        let store = fake.store()
        await store.refresh()
        let provider = Self.provider(box, joined: store)
        // A hidden section removes nothing, even on a click.
        await #expect(throws: PageError.self) {
            try await provider.call(MachineSectionPageProvider.removeOp, params: ["row": "joined:m_1"], context: Self.context)
        }
        provider.setShown(true)
        let scripted = PageCallContext(page: PageDescriptor.machines.id, userGesture: false, gestureEvent: nil)
        await #expect(throws: PageError.self) {
            try await provider.call(MachineSectionPageProvider.removeOp, params: ["row": "joined:m_1"], context: scripted)
        }
        for row in ["local", "fleet-lane-7", "m_1", ""] {
            await #expect(throws: PageError.self) {
                try await provider.call(MachineSectionPageProvider.removeOp, params: ["row": .string(row)], context: Self.context)
            }
        }
        #expect(fake.removed.isEmpty)
        let answer = try await provider.call(MachineSectionPageProvider.removeOp, params: ["row": "joined:m_1"], context: Self.context)
        #expect(answer["removed"]?.boolValue == true)
        #expect(fake.removed == ["m_1"])
    }

    /// New Workspace on a joined Mac reached through the hub alone (hq#11046): the first ask is the
    /// person's click, on an online joined Mac's own `joined:<id>` row; `again` (the page asking while that
    /// Mac's card waits) runs only while a click's ask is waiting, and stops once that Mac answered.
    @Test func openJoinedAsksAMacOnlyOnAClickAndAgainOnlyWhileItsCardWaits() async throws {
        let box = Box()
        let mac = JoinedMachine(id: "m_mini", name: "studio-mini", state: .online, platform: "macos", mintedBy: nil)
        box.rows.append(.joined(mac, health: nil))
        box.rows.append(.joined(JoinedMachine(id: "m_lane", name: "lane-vm-3", state: .online, platform: "linux", mintedBy: nil), health: nil))
        box.rows.append(.joined(JoinedMachine(id: "m_off", name: "old-mini", state: .offline, platform: "macos", mintedBy: nil), health: nil))
        box.answers = [.consentRequired, .consentRequired, .opened]
        let provider = MachineSectionPageProvider(dependencies: .init(
            rows: { box.rows }, style: { .compact }, joined: { nil }, newWorkspace: { _ in true }, addMachine: { true },
            present: { _, _ in }, menu: { _, _ in nil },
            openJoined: { machine in
                box.asked.append(machine.id)
                return box.answers.isEmpty ? .opened : box.answers.removeFirst()
            }))
        let scripted = PageCallContext(page: PageDescriptor.machines.id, userGesture: false, gestureEvent: nil)
        let op = MachineSectionPageProvider.openJoinedOp
        // An offline Mac, a row the section doesn't show, this Mac: refused, even on a click.
        for row in ["joined:m_off", "joined:m_gone", "local"] {
            await #expect(throws: PageError.self) { try await provider.call(op, params: ["row": .string(row)], context: Self.context) }
        }
        // No click, and no ask of the row waiting: refused.
        await #expect(throws: PageError.self) { try await provider.call(op, params: ["row": "joined:m_mini"], context: scripted) }
        await #expect(throws: PageError.self) {
            try await provider.call(op, params: ["row": "joined:m_mini", "again": true], context: scripted)
        }
        #expect(box.asked.isEmpty)
        let first = try await provider.call(op, params: ["row": "joined:m_mini"], context: Self.context)
        #expect(first["state"]?.stringValue == "consent_required")
        let second = try await provider.call(op, params: ["row": "joined:m_mini", "again": true], context: scripted)
        #expect(second["state"]?.stringValue == "consent_required")
        let third = try await provider.call(op, params: ["row": "joined:m_mini", "again": true], context: scripted)
        #expect(third["state"]?.stringValue == "opened")
        // Answered: asking again needs a click.
        await #expect(throws: PageError.self) {
            try await provider.call(op, params: ["row": "joined:m_mini", "again": true], context: scripted)
        }
        #expect(box.asked == ["m_mini", "m_mini", "m_mini"])
        // An online joined Linux box dials the same way on a click (its join is its consent).
        let linux = try await provider.call(op, params: ["row": "joined:m_lane"], context: Self.context)
        #expect(linux["state"]?.stringValue == "opened")
        #expect(box.asked == ["m_mini", "m_mini", "m_mini", "m_lane"])
    }

    /// acpmux's probe refusals as the page reads them, and the route of a joined Mac among acpmux's.
    @Test func aProbeRefusalAndARouteReadAsThePageAndTheAppNeedThem() {
        #expect(JoinedDialAnswer(refusal: "consent_required") == .consentRequired)
        #expect(JoinedDialAnswer(refusal: "consent_declined") == .consentDeclined)
        #expect(JoinedDialAnswer(refusal: "service.unknown").json == ["state": "unavailable", "reason": "service.unknown"])
        #expect(JoinedDialAnswer(refusal: nil) == .unavailable("machine.unreachable"))
        // Only a Mac answers the ask; a Linux box that still asks reads as one to update.
        #expect(JoinedDialAnswer(refusal: "consent_required", platform: "macOS") == .consentRequired)
        #expect(JoinedDialAnswer(refusal: "consent_required", platform: "linux") == .unavailable(JoinedDialAnswer.outdated))
        #expect(JoinedDialAnswer(refusal: "consent_declined", platform: "linux") == .consentDeclined)
        let routes: [[String: Any]] = [["daemonId": "k1", "host": "studio-mini"], ["daemonId": "k2", "host": "Air"],
                                       ["daemonId": "k3", "host": "twin"], ["daemonId": "k4", "host": "twin"]]
        let byPeer = JoinedMachine(id: "m", name: "x", state: .online, meshPeerId: "k2")
        #expect(byPeer.route(in: routes)?["daemonId"] as? String == "k2")
        #expect(JoinedMachine(id: "m", name: "studio-mini", state: .online, meshPeerId: "gone").route(in: routes) == nil)
        let byName = JoinedMachine(id: "m", name: "Studio-Mini", state: .online)
        #expect(byName.route(in: routes)?["daemonId"] as? String == "k1")
        #expect(JoinedMachine(id: "m", name: "twin", state: .online).route(in: routes) == nil)
        #expect(JoinedMachine(id: "m", name: "x", state: .online, platform: "macOS").isMac)
        #expect(!JoinedMachine(id: "m", name: "x", state: .online, platform: "linux").isMac)
        #expect(JoinedMachine(id: "m", name: "x", state: .online, platform: "linux").opensOverHub)
        #expect(!JoinedMachine(id: "m", name: "x", state: .offline, platform: "macos").opensOverHub)
        #expect(!JoinedMachine(id: "m", name: "x", state: .revoked, platform: "linux").opensOverHub)
    }

    /// A joined machine with no workspace link of its own has no New Workspace: its row menu is refused.
    @Test func aJoinedOnlyRowHasNoRowMenu() async throws {
        let box = Box()
        box.rows.append(.joined(JoinedMachine(id: "m_1", name: "lane-vm-3", state: .online, platform: "linux", mintedBy: nil), health: nil))
        let provider = Self.provider(box)
        await #expect(throws: PageError.self) {
            try await provider.call(MachineSectionPageProvider.menuOp, params: ["row": "joined:m_1", "menu": "row"], context: Self.context)
        }
        #expect(box.presented.isEmpty)
    }

    /// While the section is hidden its stream reads no row at all; showing it reads them again.
    @Test func aHiddenSectionReadsNoRows() async throws {
        let box = Box()
        final class Reads { var count = 0 }
        let reads = Reads()
        let store = JoinedMachineStore(service: { nil })
        let provider = MachineSectionPageProvider(dependencies: .init(
            rows: { reads.count += 1; return box.rows }, style: { .grouped }, joined: { store },
            newWorkspace: { _ in true }, addMachine: { true }, present: { _, _ in }, menu: { _, _ in nil },
            openJoined: { _ in .unavailable("test") }))
        let subscription = try await provider.subscribe(MachineSectionPageProvider.changesStream, filter: .object([:]),
                                                        context: Self.context) { _ in }
        defer { subscription.cancel() }
        for _ in 0..<20 { await Task.yield() }
        let hidden = reads.count
        provider.setShown(true)
        for _ in 0..<20 { await Task.yield() }
        provider.setShown(false)
        for _ in 0..<20 { await Task.yield() }
        let afterHide = reads.count
        // A change the shown section would show (the joined store is observed) wakes nothing while hidden.
        store.openMenu = "m_7"
        for _ in 0..<20 { await Task.yield() }
        #expect(reads.count == afterHide, "hidden: a change reads no rows")
        #expect(afterHide > hidden, "shown: the stream reads them")
        #expect(hidden == 1, "only the subscribe's own snapshot read the rows while hidden")
    }

    /// Add Machine takes no target: it opens the app's own Add Machine card, and only on the person's click.
    @Test func addMachineTakesNoTargetFromThePage() async throws {
        let box = Box()
        let provider = Self.provider(box)
        _ = try await provider.call(MachineSectionPageProvider.addMachineOp, params: ["machine": "fleet-lane-7"], context: Self.context)
        #expect(box.ran == ["add"], "a machine the page names changes nothing")
    }

    /// The row's native menu: New Workspace on This Machine from the registry, off while the link is down.
    @Test func aRowsMenuIsTheRegistrysNewWorkspaceRow() {
        let registry = ActionRegistry.standard()
        let down = MachineSectionRow(id: "h1", name: "build-host", isConnected: false, isLocal: false)
        let menu = down.menu("row", registry: registry)
        #expect(menu?.items.map(\.title) == [MachineSectionRow.newWorkspaceTitle])
        #expect(menu?.items.first?.isEnabled == false)
        #expect(down.menu("joined", registry: registry) == nil, "only a joined machine has the joined menu")
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

    /// A page that subscribes while the section is hidden still gets the newest snapshot on the first show.
    @Test func aStreamOpenedWhileHiddenSendsTheChangeOnTheFirstShow() async throws {
        let box = Box()
        let store = JoinedMachineStore(service: { nil })
        let provider = Self.provider(box, joined: store)
        var events: [JSONValue] = []
        let subscription = try await provider.subscribe(MachineSectionPageProvider.changesStream, filter: .object([:]),
                                                        context: Self.context) { events.append($0) }
        defer { subscription.cancel() }
        store.openMenu = "m_3"
        for _ in 0..<20 { await Task.yield() }
        #expect(events.isEmpty, "hidden: no event")
        provider.setShown(true)
        #expect(events.count == 1)
        #expect(events.last?["openMenu"]?.stringValue == "m_3")
    }
}
