import AppKit
import CmuxNextActions
import CmuxNextDaemonService
@testable import CmuxNextApp
import CmuxNextRemote
@testable import CmuxNextServer
import Foundation
import Observation
import Testing
import CmuxNextTestSupport
import CmuxNextWakeups

/// The Machines section's machines joined through the hub: rows from `cmux machine list` (none
/// while the store has no service), online by a heartbeat within 30 s, revoked ones dropped, Revoke and Rotate through the CLI and a fresh read after, Check
/// as the Check Machine checklist on `machine doctor ID`, and the "…" menu's items.
@MainActor @Suite(.closesItsWindows, .serialized) struct JoinedMachineRowsTests {
    // The service's closures are @Sendable and run off the main actor: the fakes are not isolated to it.
    // The suite is serialized and each test drives one store, so no two calls race.
    nonisolated final class Fake: @unchecked Sendable {
        var rows: [JoinedMachine] = [Fake.machine("m_1", "lane-vm-3")]
        var lists = 0
        var revoked: [String] = []
        var rotated: [String] = []
        var removed: [String] = []
        var answer = true
        var on = true
        /// Whether the test's section is on screen, and whether a list read covers it (the window is
        /// covered while the read is in flight).
        var visible = true
        var coverOnList = false

        @MainActor func store() -> JoinedMachineStore {
            JoinedMachineStore(service: { [self] in
                guard on else { return nil }
                return MachineJoinService(
                    mint: { _ in .failure(.failed) },
                    list: { [self] in lists += 1; if coverOnList { visible = false }; return rows },
                    revoke: { [self] id in
                        revoked.append(id)
                        if answer { rows = rows.map { $0.id == id ? Fake.machine(id, $0.name, state: .revoked) : $0 } }
                        return answer
                    },
                    rotate: { [self] id in rotated.append(id); return answer },
                    remove: { [self] id in
                        removed.append(id)
                        if answer { rows.removeAll { $0.id == id } }
                        return answer
                    })
            })
        }

        static func machine(_ id: String, _ name: String, state: JoinedMachine.State = .online, mesh: String? = nil) -> JoinedMachine {
            JoinedMachine(id: id, name: name, state: state, platform: "linux", meshPeerId: mesh, joinTokenId: "jt_\(id)", mintedBy: "you@example.com")
        }
    }

    /// Remove runs `device remove` (the service's `remove`) and reads the list again: a removed
    /// machine is gone from it; a refused one stays and its row says the Remove failed.
    @Test func removeTakesTheMachineOffTheListOrSaysItFailed() async {
        let fake = Fake()
        fake.rows.append(Fake.machine("m_2", "build-box"))
        let store = fake.store()
        await store.refresh()
        #expect(await store.perform(.remove, "m_1"))
        #expect(fake.removed == ["m_1"])
        #expect(store.machines.map(\.id) == ["m_2"])
        fake.answer = false
        #expect(!(await store.perform(.remove, "m_2")))
        #expect(store.machines.map(\.id) == ["m_2"])
        #expect(store.failed["m_2"] == .remove)
    }

    @Test func theStoreListsNothingWhileItHasNoService() async {
        let fake = Fake()
        let store = fake.store()
        await store.refresh()
        #expect(store.machines.map(\.id) == ["m_1"])
        fake.on = false
        await store.refresh()
        #expect(store.machines.isEmpty, "signing out (no service) empties the section's joined rows")
        #expect(fake.lists == 1)
    }

    /// An online row turns offline once its heartbeat passes the 30 s window, offline and revoked rows
    /// stay as they are, and the next deadline is the first online row's expiry.
    @Test func anOnlineRowAgesOfflinePastTheHeartbeatWindow() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fresh = JoinedMachine(id: "m_1", name: "a", state: .online, heartbeatAt: t0)
        let older = JoinedMachine(id: "m_2", name: "b", state: .online, heartbeatAt: t0.addingTimeInterval(-10))
        let off = JoinedMachine(id: "m_3", name: "c", state: .offline, heartbeatAt: t0)
        #expect(fresh.aged(now: t0.addingTimeInterval(30)).state == .online)
        #expect(fresh.aged(now: t0.addingTimeInterval(31)).state == .offline)
        #expect(off.aged(now: t0.addingTimeInterval(1)).state == .offline, "aging never brings a row online")
        #expect(JoinedMachine(id: "m_4", name: "d", state: .online).aged(now: .distantFuture).state == .online,
                "no readable heartbeat: the CLI's word stands")
        #expect(JoinedMachine.nextExpiry([fresh, older, off]) == t0.addingTimeInterval(20))
        #expect(JoinedMachine.nextExpiry([off]) == nil)
    }

    /// The re-check deadline runs only while a section shows the rows: it starts with a visible
    /// section, stops when the last one hides, and a fire that finds none on screen reads nothing.
    @Test func theRecheckRunsOnlyWhileASectionIsVisible() async {
        let now = Date()
        let fake = Fake()
        fake.rows = [JoinedMachine(id: "m_1", name: "a", state: .online, heartbeatAt: now.addingTimeInterval(-10))]
        let store = fake.store()
        await store.refresh()
        #expect(!store.isAging, "no section shows the rows: no deadline")
        let section = NSObject()
        var visible = true
        store.startAging(section) { visible }
        #expect(store.isAging)
        store.stopAging(section)
        #expect(!store.isAging, "the last section hid: the deadline stops")
        store.startAging(section) { visible }
        visible = false
        store.pauseAging()
        #expect(!store.isAging, "the window was covered: the deadline stops at once, no wakeup at the expiry")
        store.startAging(section) { visible }
        let reads = fake.lists
        await store.ageFired()
        #expect(fake.lists == reads, "a fire with no section on screen reads nothing")
        #expect(!store.isAging, "a covered window costs no wakeups: the deadline stops until it shows")
        store.resumeAging()
        #expect(!store.isAging, "still covered: resuming starts nothing")
        visible = true
        store.resumeAging()
        #expect(store.isAging, "the window shows again: aging restarts at once")
        store.stopAging(section)
        #expect(!store.isAging)
        visible = false
        await store.ageFired()
        #expect(!store.isAging, "no section registered: a fire never reschedules")
        fake.rows = [JoinedMachine(id: "m_1", name: "a", state: .offline, heartbeatAt: now.addingTimeInterval(-10))]
        await store.refresh()
        visible = true
        store.startAging(section) { visible }
        #expect(!store.isAging, "no online row: nothing can age, no deadline")
        store.stopAging(section)
    }

    /// A section that registers while its window is covered sets no deadline: a covered window costs
    /// no wakeups from the start, and showing it starts aging (``JoinedMachineStore/resumeAging()``).
    @Test func aSectionRegisteringWhileCoveredSetsNoDeadline() async {
        let fake = Fake()
        fake.rows = [JoinedMachine(id: "m_1", name: "a", state: .online, heartbeatAt: Date().addingTimeInterval(-10))]
        let store = fake.store()
        await store.refresh()
        let section = NSObject()
        fake.visible = false
        store.startAging(section) { fake.visible }
        #expect(!store.isAging, "registered while covered: no deadline")
        fake.visible = true
        store.resumeAging()
        #expect(store.isAging, "the window shows: aging starts")
        store.stopAging(section)
    }

    /// A list read that lands after every window was covered sets no deadline, whether the read was
    /// a fire's or any other (a refresh, Add Device's card).
    @Test func aReadLandingAfterTheWindowWasCoveredSetsNoDeadline() async {
        let fake = Fake()
        fake.rows = [JoinedMachine(id: "m_1", name: "a", state: .online, heartbeatAt: Date().addingTimeInterval(-10))]
        let store = fake.store()
        await store.refresh()
        let section = NSObject()
        store.startAging(section) { fake.visible }
        #expect(store.isAging)
        fake.coverOnList = true
        await store.ageFired()
        #expect(!fake.visible, "the window was covered while the fire's read was in flight")
        #expect(!store.isAging, "the fire's read landed covered: no next deadline")
        fake.coverOnList = false
        await store.refresh()
        #expect(!store.isAging, "a plain read landing covered: no deadline either")
        fake.visible = true
        store.resumeAging()
        #expect(store.isAging)
        store.stopAging(section)
    }

    /// Removing the last visible section while a covered one stays registered stops the deadline: the
    /// covered window never wakes for the section that went.
    @Test func removingTheLastVisibleSectionLeavesACoveredOneNoDeadline() async {
        let fake = Fake()
        fake.rows = [JoinedMachine(id: "m_1", name: "a", state: .online, heartbeatAt: Date().addingTimeInterval(-10))]
        let store = fake.store()
        await store.refresh()
        let shown = NSObject(), covered = NSObject()
        store.startAging(covered) { false }
        store.startAging(shown) { true }
        #expect(store.isAging)
        store.stopAging(shown)
        #expect(!store.isAging, "only a covered section is left: the deadline is cancelled and never fires")
        store.startAging(shown) { true }
        let other = NSObject()
        store.startAging(other) { true }
        store.stopAging(shown)
        #expect(store.isAging, "another section is still on screen: the deadline stays")
        store.stopAging(other)
        store.stopAging(covered)
    }

    /// While visible, a fire reads the list once; a row the read did not renew ages offline.
    @Test func aFireReadsOnceAndAgesWhatTheReadDidNotRenew() async {
        let past = Date().addingTimeInterval(-200)
        let fake = Fake()
        fake.rows = [JoinedMachine(id: "m_1", name: "a", state: .online, heartbeatAt: past)]
        let store = fake.store()
        await store.refresh()
        let section = NSObject()
        store.startAging(section) { true }
        let reads = fake.lists
        await store.ageFired()
        #expect(fake.lists == reads + 1)
        #expect(store.machines.first?.state == .offline)
        #expect(!store.isAging, "no online row left: no next deadline")
        store.stopAging(section)
    }

    /// A covered window coming back into view after its rows' heartbeat passed reads at once: the
    /// deadline is due now, not a window later.
    @Test func aWindowShownAgainPastTheExpiryReadsAtOnce() async {
        let fake = Fake()
        fake.rows = [JoinedMachine(id: "m_1", name: "a", state: .online, heartbeatAt: Date().addingTimeInterval(-200))]
        let store = fake.store()
        await store.refresh()
        let section = NSObject()
        var visible = false
        store.startAging(section) { visible }
        await store.ageFired()
        let reads = fake.lists
        visible = true
        store.resumeAging()
        for _ in 0..<400 where fake.lists == reads { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        #expect(fake.lists == reads + 1, "shown again past the expiry: one read now")
        #expect(store.machines.first?.state == .offline)
        store.stopAging(section)
    }

    /// Switching account or team empties the rows at once (the old team's machines never show under
    /// the new one) and reads the new account's list; a read still in flight for the old one is dropped.
    @Test func switchingAccountEmptiesThenReadsTheNewList() async {
        let fake = Fake()
        let store = fake.store()
        await store.refresh()
        #expect(store.machines.map(\.id) == ["m_1"])
        let stale = store.beginRead()
        fake.rows = [Fake.machine("m_9", "other-team-box")]
        await store.switchedAccount()
        #expect(store.machines.map(\.id) == ["m_9"])
        store.finishRead([Fake.machine("m_1", "lane-vm-3")], ticket: stale)
        #expect(store.machines.map(\.id) == ["m_9"], "the old account's read lands late and is dropped")
    }

    /// The follow runs on an account change, not only on signing in or out.
    @Test func theStoreFollowsAnAccountChange() async {
        let fake = Fake()
        let account = AccountBox()
        let store = fake.store().following(account: { account.key })
        await store.refresh()
        let reads = fake.lists
        fake.rows = [Fake.machine("m_9", "other-team-box")]
        account.key = "u_1|team_b"
        for _ in 0..<400 where fake.lists == reads { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        #expect(fake.lists == reads + 1)
        #expect(store.machines.map(\.id) == ["m_9"])
    }

    /// A section hears its window's occlusion reports through the app's one occlusion observer until it
    /// stops following or goes away (no observer of its own).
    @Test func aSightFollowerHearsItsWindowUntilItStops() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false // the test holds it; close must not release it a second time
        defer { window.close() }
        var heard = 0
        var owner: NSObject? = NSObject()
        FrameScheduler.followSight(of: window, owner: owner!) { heard += 1 }
        // A second follower on the same window that stays: the app's one observer tells every follower of a report in
        // one delivery, so its count says the report was delivered, also when the follower under test is not told.
        let witness = NSObject()
        var delivered = 0
        FrameScheduler.followSight(of: window, owner: witness) { delivered += 1 }
        defer { FrameScheduler.unfollowSight(of: window, owner: witness) }
        func report() async throws {
            let before = delivered
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window) // global-notice-allow: the app's one occlusion observer (FrameScheduler.watchSight) listens on .default and takes no center
            // The observer delivers on the main queue: yield the main actor until it has.
            let deadline = ContinuousClock.now + .seconds(5)
            while delivered == before, ContinuousClock.now < deadline { await Task.yield() }
            try #require(delivered > before, "the app's occlusion observer did not deliver the report")
        }
        try await report()
        #expect(heard == 1)
        owner = nil
        try await report()
        #expect(heard == 1, "the owner went away: it is not told")
        let other = NSObject()
        FrameScheduler.followSight(of: window, owner: other) { heard += 1 }
        FrameScheduler.unfollowSight(of: window, owner: other)
        try await report()
        #expect(heard == 1, "unfollowed: not told")
    }

    @MainActor @Observable final class AccountBox {
        var key: String? = "u_1|team_a"
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
        // The row's caption says so: the page reads `failed` (webviews/src/pages/machines, joinedCaption).
    }

    @Test func joinedRowsFollowTheConnectedOnesAndCarryWhoMadeTheirLine() {
        let health = MachineHealthStore()
        let online = Fake.machine("m_1", "lane-vm-3")
        let revoked = Fake.machine("m_2", "old-box", state: .revoked)
        let row = MachineSectionRow.joined(online, health: health.reports[JoinedMachine.healthID("m_1")])
        #expect(row.id == "joined:m_1")
        #expect(row.isConnected)
        #expect(row.joined?.mintedBy == "you@example.com")
        #expect(!MachineSectionRow.joined(revoked, health: nil).isConnected)
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
        let runs = AddMachineRuns(services: host.services())
        runs.beginJoinedCheck(id: "m_1", name: "lane-vm-3")
        _ = await runs.finished()
        #expect(host.commands == [.joinedDoctor(id: "m_1")])
        #expect(HostCommand.joinedDoctor(id: "m_1").arguments == ["machine", "doctor", "m_1", "--json", "--cloud-token-stdin"])
        #expect(HostCommand.joinedDoctor(id: "m_1").needsAccount)
        #expect(!HostCommand.doctor(host: "h", fix: false).needsAccount)
        #expect(runs.run?.name == "lane-vm-3")
        #expect(host.recorded.map(\.0) == ["joined:m_1"], "the row's mark follows the check")
        runs.fix()
        #expect(host.commands.count == 1, "the minting end fixes nothing on another machine")
        // The card lists only the steps the joined check sent, no ssh enroll rows (its checklist starts empty).
        #expect(runs.run?.events.first == .start(joined: true))
    }

    @Test func theJoinedCardOffersOnlyDone() async {
        let fake = MachineJoinLineFlowTests.Fake()
        fake.rows = [MachineJoinLineFlowTests.Fake.joined("jt_1")]
        let devices = AddDeviceFlowTests.Fake()
        let model = fake.deviceModel(MachineJoinLineFlowTests.services(devices, fake))
        await model.begin(way: .joinLine)
        await model.joinLine?.mint()
        #expect(model.buttons.map(\.action) == [.done])
        #expect(model.perform(.done), "Done closes the card")
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

    /// Each row shows its name, platform and online state; a revoked machine drops out of the section.
    @Test func theSectionListsHubMachinesWithTheirPlatformAndDropsRevokedOnes() {
        let store = JoinedMachineStore(service: { nil })
        store.apply([Fake.machine("m_1", "lane-vm-3"), Fake.machine("m_2", "gpu-west", state: .offline),
                     Fake.machine("m_3", "old-box", state: .revoked)])
        let rows = MachineSectionRow.rows(MachineRegistry(local: DaemonService()), health: MachineHealthStore(), joined: store)
            .filter { $0.kind == .joined }
        #expect(rows.map(\.name) == ["lane-vm-3", "gpu-west"], "the revoked machine has no row")
        #expect(rows.map(\.isConnected) == [true, false])
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
        let runs = AddMachineRuns(services: host.services())
        runs.beginJoinedCheck(id: "m_1", name: "lane-vm-3")
        #expect(await runs.finished() == "Sign in to cmux to check this machine.")
        #expect(runs.run?.events.last == .stop("Sign in to cmux to check this machine."))
    }

    @Test func aJoinedCheckThatFailsAfterItsRowsKeepsTheReason() async {
        let host = AddMachineFlowTests.FakeHost()
        host.scripts = [[AddMachineFlowTests.step("listed", "ok")]]
        host.stops = [HostCLIStopFixture(message: "the hub stopped answering")]
        let runs = AddMachineRuns(services: host.services())
        runs.beginJoinedCheck(id: "m_1", name: "lane-vm-3")
        _ = await runs.finished()
        // The card adds a Check it row for a stop with no row open (webviews checklist test).
        #expect(runs.run?.events == [.start(joined: true), .line(AddMachineFlowTests.step("listed", "ok")), .stop("the hub stopped answering")])
    }

    @Test func checkOnADaemonRowRecordsUnderThatRow() async {
        let host = AddMachineFlowTests.FakeHost()
        let doctor = [AddMachineFlowTests.step("listed", "ok")]
        host.scripts = [doctor + [AddMachineFlowTests.report("lane-vm-3", "m_1", ok: true, doctor)]]
        let runs = AddMachineRuns(services: host.services())
        runs.beginJoinedCheck(id: "m_1", name: "lane-vm-3", rowID: "ssh-7")
        _ = await runs.finished()
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
}
