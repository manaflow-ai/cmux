import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextRemote
@testable import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// A launch's first connect attempts fail while the daemon (or this Mac's Chief owner) still starts.
/// The store went `.failed` on each, so every launch read "Unreachable" in red on the Chief row and
/// "<machine> is offline" on a remote terminal tab before the daemon answered. `.failed` is now for a
/// failure retrying cannot fix, or one that outlived the startup deadline; a drop of a connection that
/// was up reads connecting for the same grace.
@MainActor
struct DaemonStartupFailureStateTests {
    @Test func aFirstTransientFailureKeepsTheStoreConnecting() {
        let service = DaemonService()
        service.noteStartupFailure(.timedOut("server ensure"))
        #expect(service.store.connectionState == .connecting, "a first attempt that failed while the daemon starts read failed")
        #expect(service.startup == .connecting)
        #expect(service.notConnectedReason == RefusalStrings.daemonConnecting, "a timed-out attempt reads the service still starting")
    }

    /// A daemon error a person reads never names the command, its code, the socket or cmux-tui.
    @Test func aDaemonErrorReadsPlainWords() {
        let refusal = DaemonError.command(cmd: "workspace.place", message: "That workspace is no longer open.", code: "not_found")
        #expect(RefusalStrings.describe(refusal) == "That workspace is no longer open.")
        #expect(RefusalStrings.describe(DaemonError.timedOut("workspace.place (no reply within 2.0 seconds)")) == RefusalStrings.daemonTimedOut)
        #expect(RefusalStrings.describe(DaemonError.connectionClosed(reason: "eof")) == RefusalStrings.daemonConnecting)
        for error in [DaemonError.notConnected, .daemonShutdown, .connectFailed(path: "/tmp/cmux.sock", errno: 2),
                      .socketPathTooLong("/tmp/x"), .malformedResponse("bad"), .wrongApp("other"),
                      .binaryNotFound(searched: ["/a"]), .launchFailed("exit 3"), .invalidSessionName("x"), refusal] {
            let shown = RefusalStrings.describe(error)
            for word in ["cmux-tui", "socket", "workspace.place", "[not_found]", "daemon"] {
                #expect(!shown.contains(word), "\(error) reads \(shown)")
            }
        }
    }

    /// Cloud's `link_ended_detail` read only "connection ended" and dropped the failure that ended
    /// the daemon connection (#32954); the detail names both.
    @Test func anEndedDetailNamesTheDaemonConnectionsFailure() {
        struct Ended: Error, CustomStringConvertible { var description: String { "connection ended" } }
        let service = DaemonService()
        #expect(service.endedDetail(Ended()) == "connection ended")
        let failure = DaemonError.timedOut("server ensure")
        service.noteStartupFailure(failure)
        #expect(service.endedDetail(Ended()) == "connection ended; the daemon connection failed: \(failure.description)")
    }

    @Test func aPermanentFailureShowsAtOnce() {
        let service = DaemonService()
        let error = DaemonError.wrongApp("not-cmux")
        service.noteStartupFailure(error)
        #expect(service.store.connectionState == .failed(error.description))
        #expect(service.startup == .unavailable(error))
    }

    /// The launcher could not be made: nothing retries, so the window shows it at once too.
    @Test func aFailureNothingRetriesShowsAtOnce() {
        let service = DaemonService()
        let error = DaemonError.launchFailed("no launcher")
        service.noteStartupFailure(error, retries: false)
        #expect(service.store.connectionState == .failed(error.description))
        #expect(service.startup == .unavailable(error), "the window waited for a deadline that was never armed")
    }

    @Test func aFailureThatOutlivesTheDeadlineShowsFailed() async {
        let service = DaemonService()
        service.startupClock = NowClock()
        let error = DaemonError.timedOut("server ensure")
        service.noteStartupFailure(error)
        #expect(service.store.connectionState == .connecting)
        service.armStartupDeadline()
        for await unavailable in ObservationStream({ service.startup.isUnavailable }) where unavailable { break }
        #expect(service.store.connectionState == .failed(error.description), "a lasting failure must still show")
        // Later attempts past the deadline keep it failed, with their own cause.
        service.noteStartupFailure(.timedOut("again"))
        #expect(service.store.connectionState == .failed(DaemonError.timedOut("again").description))
    }

    /// The Chief row: a drop (the owner restarting, a version handoff) reads connecting, not
    /// "Unreachable", until the store's drop grace ends; a drop that lasts reads unreachable.
    @Test func aDroppedServerReadsConnectingUntilTheGraceEnds() async throws {
        let reach = try ServerReach.localChief(homeID: "abcd1234", socket: "/private/tmp/cn-drop-grace.sock", name: "Chief")
        let (chief, machines) = try ChiefRowUpdateStatusTests.olderServer(reach)
        let store = chief.daemon.store
        store.dropGrace.clock = NowClock()
        store.connectionState = .disconnected("daemon shut down")
        #expect(store.dropGrace.isActive)
        #expect(chief.sidebarMachine(machines: machines).status == .connecting)
        for await grace in ObservationStream({ store.dropGrace.isActive }) where !grace { break }
        #expect(chief.sidebarMachine(machines: machines).status == .unreachable)
    }

    @Test func aFirstConnectThatFailedIsNoDrop() {
        let store = DaemonStore()
        store.markFailed("incompatible")
        #expect(!store.dropGrace.isActive, "only a connection that was up starts the drop grace")
    }

    /// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the f*** up". This Mac's header drew a
    /// spinner from the first frame of every daemon restart, handoff and launch connect (with more than one
    /// machine listed). It now waits out the same 10 s grace as one list's "Connecting…" label: a connect that
    /// heals within it draws nothing, one that lasts draws the spinner, and a connected Mac never waits.
    @Test func thisMacsHeaderDrawsNoSpinnerForAConnectUnderTheGrace() async {
        let grace = SidebarPlaceholderGrace(wait: .seconds(10), clock: NowClock())
        let local = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Mac", kind: .local, status: .connecting)), nodes: [])
        await withCheckedContinuation { (ended: CheckedContinuation<Void, Never>) in
            grace.onEnd = { ended.resume() }
            let held = grace.holdingConnectingLabels([local])
            let machine = try? #require(held.first?.machine)
            #expect(machine?.holdsStatusLabel == true)
            #expect(machine.map { SectionHeaderRowView.tone(SectionHeaderRowView.drawn($0), hostGroup: false) } == .some(nil), "no spinner within the grace")
        }
        grace.onEnd = nil
        let lasting = try? #require(grace.holdingConnectingLabels([local]).first?.machine)
        #expect(lasting.map { SectionHeaderRowView.tone(SectionHeaderRowView.drawn($0), hostGroup: false) } == .working, "a lasting connect draws the spinner")
        let connected = SidebarMachine(id: .local, name: "Mac", kind: .local, status: .connected)
        #expect(SectionHeaderRowView.tone(connected, hostGroup: false) == nil)
    }

    /// One list's "Connecting…" label waits out the grace; a connected machine is never held.
    @Test func theConnectingLabelWaitsOutTheGrace() async {
        let grace = SidebarPlaceholderGrace(wait: .seconds(10), clock: NowClock())
        let connecting = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("vm-a"), name: "A", kind: .cloud, status: .connecting)), nodes: [])
        let connected = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("vm-b"), name: "B", kind: .cloud, status: .connected)), nodes: [])
        let local = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Mac", kind: .local, status: .connecting)), nodes: [])
        // Two waits run (A and This Mac): the continuation resumes when both ended, once.
        var ends = 0
        await withCheckedContinuation { (ended: CheckedContinuation<Void, Never>) in
            grace.onEnd = { ends += 1; if ends == 2 { ended.resume() } }
            let held = grace.holdingConnectingLabels([connecting, connected, local])
            #expect(held.map { $0.machine?.holdsStatusLabel } == [true, false, true])
        }
        grace.onEnd = nil
        #expect(grace.holdingConnectingLabels([connecting]).first?.machine?.holdsStatusLabel == false, "a lasting connect still says so")
    }

    /// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up". An ssh machine whose
    /// link dropped, or cannot be reached, redials on its own: its header showed a spinner and
    /// "Reconnecting…" from the first frame of every drop. Now it keeps the connected look for the grace,
    /// and a state a person must act on is said at once.
    @Test func aDroppedLinkSaysNothingInItsHeaderUntilTheGrace() async {
        let grace = SidebarPlaceholderGrace(wait: .seconds(10), clock: NowClock())
        func ssh(_ id: String, _ status: SidebarMachine.Status) -> CmuxNextSidebar.SidebarSection {
            CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: MachineID(id), name: id, kind: .ssh, status: status)), nodes: [])
        }
        let healing: [SidebarMachine.Status] = [.reconnecting, .unreachable, .offline, .connecting]
        let needsPerson: [SidebarMachine.Status] = [.authFailed, .installRequired, .updateRequired, .failed]
        let sections = (healing + needsPerson).enumerated().map { ssh("m\($0.offset)", $0.element) }
        let held = grace.holdingConnectingLabels(sections).compactMap(\.machine)
        #expect(held.map(\.holdsStatusLabel) == healing.map { _ in true } + needsPerson.map { _ in false })
        for machine in held.prefix(healing.count) {
            let drawn = SectionHeaderRowView.drawn(machine)
            #expect(SectionHeaderRowView.tone(drawn, hostGroup: false) == .success, "the connected dot, no spinner: \(machine.status)")
            #expect(SectionHeaderRowView.statusText(drawn.status, hostGroup: false) == nil, "no words: \(machine.status)")
        }
        for machine in held.dropFirst(healing.count) {
            #expect(SectionHeaderRowView.statusText(SectionHeaderRowView.drawn(machine).status, hostGroup: false) != nil,
                    "a person must act: said at once (\(machine.status))")
        }
        // Past the grace, a drop that lasts is said, once, in place.
        let late = ssh("late", .reconnecting), lasting = SidebarPlaceholderGrace(wait: .seconds(10), clock: NowClock())
        await withCheckedContinuation { (ended: CheckedContinuation<Void, Never>) in
            lasting.onEnd = { ended.resume() }
            #expect(lasting.holdingConnectingLabels([late]).first?.machine?.holdsStatusLabel == true)
        }
        lasting.onEnd = nil
        let said = lasting.holdingConnectingLabels([late]).first?.machine ?? SidebarMachine(id: MachineID("none"), name: "", kind: .ssh)
        #expect(!said.holdsStatusLabel)
        #expect(SectionHeaderRowView.statusText(SectionHeaderRowView.drawn(said).status, hostGroup: false) == SectionHeaderRowView.statusWords(.reconnecting))
    }
}

/// A clock whose sleeps complete on the next task turn.
private struct NowClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until _: Instant, tolerance _: Duration?) async throws {}
}
