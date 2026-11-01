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
        #expect(service.notConnectedReason == RefusalStrings.describe(DaemonError.timedOut("server ensure")), "the attempt's cause still answers")
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

    /// One list's "Connecting…" label waits out the grace; a connected or local machine is never held.
    @Test func theConnectingLabelWaitsOutTheGrace() async {
        let grace = SidebarPlaceholderGrace(wait: .seconds(10), clock: NowClock())
        let connecting = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("vm-a"), name: "A", kind: .cloud, status: .connecting)), nodes: [])
        let connected = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("vm-b"), name: "B", kind: .cloud, status: .connected)), nodes: [])
        let local = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Mac", kind: .local, status: .connecting)), nodes: [])
        await withCheckedContinuation { (ended: CheckedContinuation<Void, Never>) in
            grace.onEnd = { ended.resume() }
            let held = grace.holdingConnectingLabels([connecting, connected, local])
            #expect(held.map { $0.machine?.holdsStatusLabel } == [true, false, false])
        }
        grace.onEnd = nil
        #expect(grace.holdingConnectingLabels([connecting]).first?.machine?.holdsStatusLabel == false, "a lasting connect still says so")
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
