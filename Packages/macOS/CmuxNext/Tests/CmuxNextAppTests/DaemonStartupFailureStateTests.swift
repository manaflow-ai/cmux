import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextWakeupsTestSupport
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

    /// Even an already expired grace cannot turn automatic recovery into a line or spinner.
    @Test func aReconnectStaysQuietAfterSixtySeconds() async throws {
        let clock = ManualClock()
        let grace = SidebarPlaceholderGrace(wait: .seconds(10), clock: clock)
        let section = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: MachineID("long-reconnect"), name: "Studio", kind: .ssh,
                                                                  status: .reconnecting)), nodes: [])
        let (expired, finish) = AsyncStream<Void>.makeStream()
        grace.onEnd = { finish.yield(()); finish.finish() }
        // Expire the existing grace deterministically, then project the still-reconnecting machine.
        #expect(!grace.allows(section.id))
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(60))
        for await _ in expired { break }
        grace.onEnd = nil
        let shown = try #require(grace.holdingConnectingLabels([section]).first?.machine)
        #expect(shown.holdsStatusLabel)
        let drawn = SectionHeaderRowView.drawn(shown)
        #expect(SectionHeaderRowView.statusText(drawn.status, hostGroup: false) == nil)
        #expect(SectionHeaderRowView.tone(drawn, hostGroup: false) == .success)
        #expect(SectionHeaderRowView.statusWords(drawn.status) == SectionHeaderRowView.statusWords(.connected))
    }

    /// Automatic reconnect never schedules a late label or spinner. Actionable failures remain visible.
    @Test func automaticReconnectKeepsHeadersQuiet() async {
        let grace = SidebarPlaceholderGrace(wait: .seconds(10), clock: NowClock())
        func machine(_ id: String, _ status: SidebarMachine.Status, kind: SidebarMachine.Kind = .ssh) -> CmuxNextSidebar.SidebarSection {
            CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: MachineID(id), name: id, kind: kind, status: status)), nodes: [])
        }
        let healing: [SidebarMachine.Status] = [.reconnecting, .unreachable, .offline, .connecting]
        let needsPerson: [SidebarMachine.Status] = [.authFailed, .installRequired, .updateRequired, .failed]
        let sections = (healing + needsPerson).enumerated().map { machine("m\($0.offset)", $0.element) }
        var timerEnded = false
        grace.onEnd = { timerEnded = true }
        for _ in 0..<2 {
            let held = grace.holdingConnectingLabels(sections).compactMap(\.machine)
            #expect(held.map(\.holdsStatusLabel) == healing.map { _ in true } + needsPerson.map { _ in false })
            for entry in held.prefix(healing.count) {
                let drawn = SectionHeaderRowView.drawn(entry)
                #expect(SectionHeaderRowView.tone(drawn, hostGroup: false) == .success)
                #expect(SectionHeaderRowView.statusText(drawn.status, hostGroup: false) == nil)
            }
            for entry in held.dropFirst(healing.count) {
                #expect(SectionHeaderRowView.statusText(SectionHeaderRowView.drawn(entry).status, hostGroup: false) != nil)
            }
            for _ in 0..<100 { await Task.yield() }
        }
        #expect(!timerEnded, "automatic recovery never schedules a late connection label")
        let local = grace.holdingConnectingLabels([machine("local", .connecting, kind: .local)]).first?.machine
        #expect(local.map { SectionHeaderRowView.tone(SectionHeaderRowView.drawn($0), hostGroup: false) } == .some(nil))
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
