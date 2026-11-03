import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextRemote
@testable import CmuxNextServer
import Foundation
import Testing
import CmuxNextTestSupport

/// The Machines section's joined machines (Labs `labs.machineJoin`): rows from `cmux machine list`
/// (none while the switch is off), Revoke and Rotate through the CLI and a fresh read after, Check
/// as the Check Machine checklist on `machine doctor ID`, and the "…" menu's items.
@MainActor @Suite(.closesItsWindows, .serialized) struct JoinedMachineRowsTests {
    // The service's closures are @Sendable and run off the main actor: the fakes are not isolated to it.
    // The suite is serialized and each test drives one store, so no two calls race.
    nonisolated final class Fake: @unchecked Sendable {
        var rows: [JoinedMachine] = [Fake.machine("m_1", "lane-vm-3")]
        var lists = 0
        var revoked: [String] = []
        var rotated: [String] = []
        var answer = true
        var on = true

        @MainActor func store() -> JoinedMachineStore {
            JoinedMachineStore(service: { [self] in
                guard on else { return nil }
                return MachineJoinService(
                    mint: { _ in .failure(.failed) },
                    list: { [self] in lists += 1; return rows },
                    revoke: { [self] id in
                        revoked.append(id)
                        if answer { rows = rows.map { $0.id == id ? Fake.machine(id, $0.name, state: .revoked) : $0 } }
                        return answer
                    },
                    rotate: { [self] id in rotated.append(id); return answer })
            })
        }

        static func machine(_ id: String, _ name: String, state: JoinedMachine.State = .online, mesh: String? = nil) -> JoinedMachine {
            JoinedMachine(id: id, name: name, state: state, platform: "linux", meshPeerId: mesh, joinTokenId: "jt_\(id)", mintedBy: "you@example.com")
        }
    }

    @Test func theStoreListsNothingWhileTheLabsSwitchIsOff() async {
        let fake = Fake()
        let store = fake.store()
        await store.refresh()
        #expect(store.machines.map(\.id) == ["m_1"])
        fake.on = false
        await store.refresh()
        #expect(store.machines.isEmpty, "turning the switch off empties the section's joined rows")
        #expect(fake.lists == 1)
    }

    @Test func aRefreshIsOneReadAndAFailedReadKeepsTheRows() async {
        let fake = Fake()
        let store = fake.store()
        await store.refresh()
        #expect(fake.lists == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.lists == 1, "no timer reads the list")
        let failing = JoinedMachineStore(service: {
            MachineJoinService(mint: { _ in .failure(.failed) }, list: { nil })
        })
        failing.apply(store.machines)
        await failing.refresh()
        #expect(failing.machines.map(\.id) == ["m_1"])
    }

    @Test func revokeRunsTheCLIAndTheRowTurnsRevoked() async {
        let fake = Fake()
        let store = fake.store()
        await store.refresh()
        let ok = await store.perform(.revoke, "m_1")
        #expect(ok)
        #expect(fake.revoked == ["m_1"])
        #expect(fake.lists == 2, "the list is read again after the revoke")
        #expect(store.machines.first?.state == .revoked)
        #expect(store.busy.isEmpty)
        #expect(store.failed.isEmpty)
    }

    @Test func aRefusedRotateSaysSoOnTheRow() async {
        let fake = Fake()
        fake.answer = false
        let store = fake.store()
        await store.refresh()
        #expect(!(await store.perform(.rotate, "m_1")))
        #expect(fake.rotated == ["m_1"])
        #expect(store.failed["m_1"] == .rotate)
        let caption = JoinedMachineStrings.caption(store.machines[0], failed: store.failed["m_1"])
        #expect(caption.contains("rotate"), "the row's caption says the rotate failed: \(caption)")
    }

    @Test func joinedRowsFollowTheConnectedOnesAndCarryWhoMadeTheirLine() {
        let health = MachineHealthStore()
        let online = Fake.machine("m_1", "lane-vm-3")
        let revoked = Fake.machine("m_2", "old-box", state: .revoked)
        let row = MachineSectionRow.joined(online, health: health.reports[JoinedMachine.healthID("m_1")])
        #expect(row.id == "joined:m_1")
        #expect(row.isConnected)
        #expect(row.joined?.mintedBy == "you@example.com")
        #expect(JoinedMachineStrings.caption(online, failed: nil) == "Online · added by you@example.com")
        #expect(!MachineSectionRow.joined(revoked, health: nil).isConnected)
        #expect(JoinedMachineStrings.caption(revoked, failed: nil).hasPrefix("Revoked"))
    }

    /// The joined machines' menu rows bound as the app binds them, on `store`.
    static func registry(_ store: JoinedMachineStore, labs: @escaping @MainActor () -> Bool = { true },
                         ran: @escaping @MainActor (JoinedMachineAction, JoinedMachine, String) -> Void = { _, _, _ in }) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        MachineSectionHostView.bindJoinedActions(into: registry, store: { store }, labsOn: labs, perform: ran)
        return registry
    }

    /// A menu's rows: each title, and whether it is enabled as AppKit asks when the menu opens.
    static func rows(_ menu: NSMenu) -> [(title: String, enabled: Bool)] {
        menu.items.filter { !$0.isSeparatorItem }.map { item in
            (item.title, (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? false)
        }
    }

    @Test func theMenuOffersCheckRotateAndRevokeAndARevokedMachineOnlyCheck() async {
        let fake = Fake()
        fake.rows = [Fake.machine("m_1", "lane-vm-3"), Fake.machine("m_2", "old-box", state: .revoked)]
        let store = fake.store()
        await store.refresh()
        let registry = Self.registry(store)
        let menu = MachineSectionHostView.joinedMenu(store.machines[0], rowID: "joined:m_1", registry: registry)
        #expect(Self.rows(menu).map { $0.title } == ["Check", "Rotate Credential", "Revoke…"])
        #expect(Self.rows(menu).map { $0.enabled } == [true, true, true])
        let gone = MachineSectionHostView.joinedMenu(store.machines[1], rowID: "joined:m_2", registry: registry)
        #expect(Self.rows(gone).map { $0.title } == ["Check"], "a revoked machine offers only Check")
        let offRegistry = Self.registry(store, labs: { false })
        let off = MachineSectionHostView.joinedMenu(store.machines[0], rowID: "joined:m_1", registry: offRegistry)
        #expect(Self.rows(off).map { $0.enabled } == [false, false, false], "nothing runs while labs.machineJoin is off")
    }

    @Test func aMenuRowRunsItsActionThroughTheRegistryOnItsRow() async throws {
        let fake = Fake()
        let store = fake.store()
        await store.refresh()
        var ran: [(JoinedMachineAction, String, String)] = []
        let registry = Self.registry(store, ran: { ran.append(($0, $1.id, $2)) })
        let menu = MachineSectionHostView.joinedMenu(store.machines[0], rowID: "ssh-1", registry: registry)
        let rotate = try #require(menu.items.first { $0.title == "Rotate Credential" })
        // A test process has no running NSApplication to dispatch the item: send its action to its
        // target as AppKit does.
        _ = (rotate.target as? NSObject)?.perform(rotate.action, with: rotate)
        #expect(ran.map { $0.0 } == [.rotate])
        #expect(ran.map { $0.1 } == ["m_1"])
        #expect(ran.map { $0.2 } == ["ssh-1"], "the row it opened on goes with it (where Check records)")
    }

    @Test func revokeAsksWithTheHeartbeatBound() {
        #expect(JoinedMachineStrings.revokeTitle("lane-vm-3") == "Revoke lane-vm-3?")
        #expect(JoinedMachineStrings.heartbeatSeconds == 30)
        #expect(JoinedMachineStrings.revokeBody.contains("within 30 seconds"))
    }

    @Test func checkRunsMachineDoctorWithTheAccountOnStdinAndOffersNoFix() async {
        let host = AddMachineFlowTests.FakeHost()
        let doctor = [AddMachineFlowTests.step("listed", "ok"), AddMachineFlowTests.step("heartbeat", "fail", "last seen 9 min ago",
                                                                                         fix: "Run cmux machine doctor on lane-vm-3")]
        host.scripts = [doctor + [AddMachineFlowTests.report("lane-vm-3", "m_1", ok: false, doctor)]]
        let model = AddMachineModel(services: host.services())
        model.beginJoinedCheck(id: "m_1", name: "lane-vm-3")
        _ = await model.finished()
        #expect(host.commands == [.joinedDoctor(id: "m_1")])
        #expect(HostCommand.joinedDoctor(id: "m_1").arguments == ["machine", "doctor", "m_1", "--json", "--cloud-token-stdin"])
        #expect(HostCommand.joinedDoctor(id: "m_1").needsAccount)
        #expect(!HostCommand.doctor(host: "h", fix: false).needsAccount)
        #expect(model.runName == "lane-vm-3")
        #expect(host.recorded.map(\.0) == ["joined:m_1"], "the row's mark follows the check")
        #expect(!model.buttons.map(\.action).contains(.fix), "the minting end fixes nothing on another machine")
        #expect(model.buttons.map(\.action) == [.copyDetails, .done])
        #expect(model.checklist.rows.map(\.step.rawValue) == ["listed", "heartbeat"], "only the steps the joined check sent, no ssh enroll rows")
    }

    @Test func theJoinedCardOffersShowInMachines() async {
        let fake = MachineJoinLineFlowTests.Fake()
        fake.rows = [MachineJoinLineFlowTests.Fake.joined("jt_1")]
        let devices = AddDeviceFlowTests.Fake()
        var shown = 0
        var services = MachineJoinLineFlowTests.services(devices, fake)
        services.showMachines = { shown += 1 }
        let model = fake.deviceModel(services)
        await model.begin(way: .joinLine)
        await model.joinLine?.mint()
        #expect(model.buttons.map(\.action) == [.showMachines, .done])
        #expect(model.perform(.showMachines), "Show in Machines closes the card")
        #expect(shown == 1)
        #expect(model.joinLine?.isWatching == false)
    }

    /// A call the test holds open: `entered` yields once the call is inside, `release()` lets it return.
    nonisolated final class Gate: @unchecked Sendable {
        let entered: AsyncStream<Void>
        private let enter: AsyncStream<Void>.Continuation
        private var held: CheckedContinuation<Void, Never>?
        var rotated = 0

        init() { (entered, enter) = AsyncStream.makeStream() }

        func hold() async {
            await withCheckedContinuation { held = $0; enter.yield() }
        }

        func waitEntered() async {
            for await _ in entered { return }
        }

        func release() { held?.resume(); held = nil }
    }

    @Test(.timeLimit(.minutes(1))) func aRevokeStaysBusyUntilItsReadLands() async {
        let gate = Gate()
        let rows = [Fake.machine("m_1", "lane-vm-3")]
        let store = JoinedMachineStore(service: {
            MachineJoinService(mint: { _ in .failure(.failed) }, list: { rows },
                               revoke: { _ in await gate.hold(); return true },
                               rotate: { _ in gate.rotated += 1; return true })
        })
        await store.refresh()
        let first = Task { await store.perform(.revoke, "m_1") }
        await gate.waitEntered()
        #expect(store.busy.contains("m_1"))
        // The menu target holds the registry weakly, as the app's long-lived one is: keep it here.
        let registry = Self.registry(store)
        let busyMenu = MachineSectionHostView.joinedMenu(rows[0], rowID: "joined:m_1", registry: registry)
        #expect(Self.rows(busyMenu).map { $0.enabled } == [true, false, false], "Rotate and Revoke wait; Check can still run")
        #expect(!(await store.perform(.rotate, "m_1")), "a second change while the first is in flight is refused")
        gate.release()
        #expect(await first.value)
        #expect(store.busy.isEmpty)
        #expect(gate.rotated == 0)
    }

    @Test(.timeLimit(.minutes(1))) func anOlderReadThatLandsLateDoesNotBringBackItsRows() async {
        let gate = Gate()
        let fake = Fake()
        let held = [Fake.machine("m_1", "lane-vm-3"), Fake.machine("m_2", "gpu-west")]
        // The first read holds until released and then returns the old list; the second returns at once.
        let store = JoinedMachineStore(service: {
            MachineJoinService(mint: { _ in .failure(.failed) }, list: {
                fake.lists += 1
                if fake.lists == 1 { await gate.hold(); return held }
                return [Fake.machine("m_1", "lane-vm-3")]
            })
        })
        let older = Task { await store.refresh() }
        await gate.waitEntered()
        await store.refresh()
        #expect(store.machines.map(\.id) == ["m_1"])
        gate.release()
        await older.value
        #expect(store.machines.map(\.id) == ["m_1"], "the read that started first must not overwrite the newer one")
        // Another reader's rows (Add Device's card) go through the same tickets.
        let ticket = store.beginRead()
        store.apply([])
        store.finishRead(held, ticket: ticket)
        #expect(store.machines.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aReadInFlightWhenTheSwitchTurnsOffShowsNothing() async {
        let gate = Gate()
        let fake = Fake()
        let store = JoinedMachineStore(service: {
            guard fake.on else { return nil }
            return MachineJoinService(mint: { _ in .failure(.failed) }, list: {
                await gate.hold()
                return [Fake.machine("m_1", "lane-vm-3")]
            })
        })
        // The switch turns off while the read runs, and nothing else reads: the read's rows are dropped.
        let read = Task { await store.refresh() }
        await gate.waitEntered()
        fake.on = false
        gate.release()
        await read.value
        #expect(store.machines.isEmpty)
        // The switch's own refresh (the section's watch) empties the rows while a read is still held,
        // and that read, landing later, does not bring them back.
        fake.on = true
        let held = Task { await store.refresh() }
        await gate.waitEntered()
        fake.on = false
        await store.refresh()
        fake.on = true
        gate.release()
        await held.value
        #expect(store.machines.isEmpty, "a read that started before the switch turned off is older than its emptying")
    }

    @Test func aJoinedMachineTheAppConnectsToStaysOneLinkedRow() {
        let machine = Fake.machine("m_1", "lane-vm-3", mesh: "ssh-7")
        let linked = MachineSectionRow(id: "ssh-7", name: "lane-vm-3", isConnected: true, isLocal: false, joined: machine)
        #expect(linked.isLinked, "the daemon's row keeps New Workspace")
        #expect(!MachineSectionRow.joined(machine, health: nil).isLinked, "a mesh-only row has no workspace link")
        #expect(MachineSectionRow(id: "ssh-8", name: "x", isConnected: true, isLocal: false).isLinked)
    }

    @Test func theSecretReachesTheCLIOnStdinOnly() async throws {
        let secret = "cmux-access-\(UUID().uuidString)"
        let cli = HostCLI(binary: URL(fileURLWithPath: "/bin/sh"), environment: { ["PATH": "/usr/bin:/bin"] })
        let run = try #require(await cli.run(["-c", #"read t; printf '%s|' "$t"; env; printf '|%s' "$0 $*""#, "sh", "--cloud-token-stdin"],
                                             secret: secret, label: "secret test"))
        #expect(run.status == 0)
        let parts = run.stdout.components(separatedBy: "|")
        #expect(parts.first == secret, "the run read it on stdin")
        #expect(!parts.dropFirst().joined().contains(secret), "not in the run's environment or argv")
    }

    @Test func aJoinedCheckThatCannotStartSaysWhy() async {
        let host = AddMachineFlowTests.FakeHost()
        host.scripts = [[]]
        host.stops = [HostCLIStopFixture(message: "Sign in to cmux to check this machine.")]
        let model = AddMachineModel(services: host.services())
        model.beginJoinedCheck(id: "m_1", name: "lane-vm-3")
        _ = await model.finished()
        #expect(model.checklist.failing?.detail == "Sign in to cmux to check this machine.")
    }

    @Test func aJoinedCheckThatFailsAfterItsRowsKeepsTheReason() async {
        let host = AddMachineFlowTests.FakeHost()
        host.scripts = [[AddMachineFlowTests.step("listed", "ok")]]
        host.stops = [HostCLIStopFixture(message: "the hub stopped answering")]
        let model = AddMachineModel(services: host.services())
        model.beginJoinedCheck(id: "m_1", name: "lane-vm-3")
        _ = await model.finished()
        #expect(model.checklist.rows.map(\.step.rawValue) == ["listed", "check"])
        #expect(model.checklist.failing?.detail == "the hub stopped answering")
    }

    @Test func checkOnADaemonRowRecordsUnderThatRow() async {
        let host = AddMachineFlowTests.FakeHost()
        let doctor = [AddMachineFlowTests.step("listed", "ok")]
        host.scripts = [doctor + [AddMachineFlowTests.report("lane-vm-3", "m_1", ok: true, doctor)]]
        let model = AddMachineModel(services: host.services())
        model.beginJoinedCheck(id: "m_1", name: "lane-vm-3", rowID: "ssh-7")
        _ = await model.finished()
        #expect(host.recorded.map(\.0) == ["ssh-7"], "the daemon row the machine shows on gets the mark")
    }

    @Test(.timeLimit(.minutes(1))) func aListAppliedFromElsewhereSupersedesAReadInFlight() async {
        let gate = Gate()
        let stale = [Fake.machine("m_old", "stale")]
        let store = JoinedMachineStore(service: {
            MachineJoinService(mint: { _ in .failure(.failed) }, list: { await gate.hold(); return stale })
        })
        let read = Task { await store.refresh() }
        await gate.waitEntered()
        store.apply([])
        gate.release()
        await read.value
        #expect(store.machines.isEmpty, "the slower read does not bring back rows")
    }

    /// A mouse event for the row's handlers (they read nothing from it).
    static var click: NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// A joined row's AppKit view on `machine`, laid out at the sidebar's width.
    static func rowView(_ machine: JoinedMachine, busy: Bool = false, failed: JoinedMachineChange? = nil, menuOpen: Bool = false,
                        actions: JoinedMachineRowView.Actions = .init()) -> JoinedMachineRowView {
        let row = MachineSectionRow.joined(machine, health: nil)
        let view = JoinedMachineRowView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: JoinedMachineMetrics.rowHeight)
        view.update(.init(row: row, machine: machine, busy: busy, failed: failed, menuOpen: menuOpen), actions)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func theRowShowsItsMoreButtonOnlyOnHoverOrWhileItsMenuIsOpen() {
        let machine = Fake.machine("m_1", "lane-vm-3")
        let idle = Self.rowView(machine)
        #expect(idle.more.alphaValue == 0, "the more button waits for the pointer")
        #expect(idle.spinner.isHidden)
        idle.setHovered(true)
        #expect(idle.more.alphaValue == 1)
        idle.setHovered(false)
        #expect(idle.more.alphaValue == 0)
        let open = Self.rowView(machine, menuOpen: true)
        #expect(open.more.alphaValue == 1 && open.more.hover.state.pressed, "an open menu keeps it shown and lit")
        let busy = Self.rowView(machine, busy: true)
        #expect(!busy.spinner.isHidden && busy.more.isHidden, "a running change shows the spinner in its place")
    }

    /// A capture showed "lane-v…" with room to spare and a spinner on idle rows once they were in a
    /// window (the spinner shows itself while it spins).
    @Test func theRowShowsItsWholeNameAndNoSpinnerWhenIdleInAWindow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = Self.rowView(Fake.machine("m_1", "lane-vm-3"))
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let needed = ceil(try #require(view.name.cell).cellSize.width)
        #expect(view.name.frame.width >= needed, "the name has room: it is not cut short")
        #expect(view.spinner.isHiddenOrHasHiddenAncestor, "an idle row shows no spinner in a window")
        let busy = Self.rowView(Fake.machine("m_2", "gpu-west"), busy: true)
        window.contentView?.addSubview(busy)
        #expect(!busy.spinner.isHidden)
    }

    @Test func theMoreButtonOpensTheActionsMenu() {
        var made = 0
        let menu = NSMenu()
        let view = Self.rowView(Fake.machine("m_1", "lane-vm-3"), actions: .init(menu: { made += 1; return menu }))
        var shown: [NSMenu] = []
        view.more.presentMenu = { menu, _ in shown.append(menu) }
        menu.addItem(withTitle: "Check", action: nil, keyEquivalent: "")
        view.more.mouseDown(with: Self.click)
        #expect(made == 1)
        #expect(shown.map(ObjectIdentifier.init) == [ObjectIdentifier(menu)], "the registry's menu, made on the press")
    }

    @Test func newWorkspaceNeedsALinkToTheMachine() {
        var opened = 0
        let meshOnly = Self.rowView(Fake.machine("m_1", "lane-vm-3"), actions: .init(newWorkspace: { opened += 1 }))
        #expect(!meshOnly.add.isEnabled, "a machine reached through the mesh alone has no link for a workspace")
        #expect(meshOnly.add.themedToolTip == JoinedMachineStrings.noWorkspace)
        let failed = Self.rowView(Fake.machine("m_1", "lane-vm-3"), failed: .rotate)
        #expect(failed.snapshot?.caption == JoinedMachineStrings.caption(Fake.machine("m_1", "lane-vm-3"), failed: .rotate))
        #expect(failed.snapshot?.failed == true)
        #expect(opened == 0)
    }

    /// The rows as a picture: `Packages/macOS/CmuxNext/.build/machines-joined-rows.png`.
    @Test func theJoinedRowsRender() throws {
        _ = NSApplication.shared
        let rows = [Self.rowView(Fake.machine("m_1", "lane-vm-3"), menuOpen: true),
                    Self.rowView(Fake.machine("m_2", "gpu-west", state: .offline)),
                    Self.rowView(Fake.machine("m_3", "old-box", state: .revoked)),
                    Self.rowView(Fake.machine("m_4", "build-box"), busy: true)]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 2
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(rows.count) * (JoinedMachineMetrics.rowHeight + 2))
        stack.layoutSubtreeIfNeeded()
        let image = try AddMachineShotsTests.render(stack)
        #expect(image.size.height >= 4 * JoinedMachineMetrics.rowHeight)
        let out = AddServerShotsTests.packageRoot.appending(path: ".build/machines-joined-rows.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AddServerShotsTests.png(AddServerShotsTests.contactSheet([("joined rows", image)])).write(to: out)
    }
}
