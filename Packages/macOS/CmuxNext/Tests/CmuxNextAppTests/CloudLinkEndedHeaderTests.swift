import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing

/// A Cloud machine on the app server's link (``CloudLinkSession``) that ran and then lost its
/// link ("disconnected, click to connect") is not a machine that failed to start: its sidebar
/// header says Disconnected, and the session reads the machine list again, so a machine the idle
/// auto-pause parked while cmux stayed in front reads "Paused (idle)" instead of keeping its
/// stale running record. A machine the provider failed still reads "Failed to start".
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudLinkEndedHeaderTests {
    /// A Cloud machine with `status` whose app link refuses every connect with `error` (by default
    /// the link-down a dropped link answers).
    static func session(status: CloudMachine.Status,
                        error: CloudLinkError = .disconnected(reason: "link down")) -> CloudMachineSession {
        let id = "vm-ended-\(UUID().uuidString.prefix(8))"
        let session = CloudMachineSession(machine: CloudMachine(id: id, status: status, displayName: "Ended VM"),
                                          appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: EndedLinkResolver(error: error)),
                                          localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        return session
    }

    /// Connects (a click) and waits for the link to end.
    static func connectAndEnd(_ session: CloudMachineSession) async {
        session.connect(origin: .user)
        for await ended in ObservationStream({ session.linkEnded != nil }) where ended { break }
    }

    @Test func aRunningMachineWhoseLinkDroppedReadsDisconnectedNotFailedToStart() async {
        let session = Self.session(status: .running)
        defer { session.disconnect() }
        await Self.connectAndEnd(session)
        #expect(session.stage.failure != nil, "the link ended: the progress view still offers a connect")
        let header = CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard())
        #expect(header.status != .failed, "a machine that ran did not fail to start")
        #expect(SectionHeaderRowView.statusText(header.status, hostGroup: false) == "Disconnected")
        #expect(SectionHeaderRowView.statusWords(header.status) == "Disconnected")
        #expect(header.status.needsAttention, "it connects again on a click")
        #expect(header.detail == session.linkEnded, "the tooltip says why it ended")
    }

    /// The idle auto-pause parked the machine behind a frontmost cmux: its link ends and the
    /// record still says running. The ended link reads the list again at once (forced, past the
    /// 30 s throttle: soon machines pause between tool calls), reads as on its way (a spinner,
    /// never "Disconnected") until it answers, and the header follows the record to Paused (idle).
    @Test func anEndedLinkReadsTheMachineListAgainAndShowsTheIdlePause() async {
        let session = Self.session(status: .running)
        defer { session.disconnect() }
        let (reads, read) = AsyncStream.makeStream(of: Bool.self)
        let (answers, answer) = AsyncStream.makeStream(of: Void.self)
        session.refresher = { [weak session] force in
            read.yield(force)
            for await _ in answers { break }
            session?.machine.status = .paused
            session?.machine.pauseReason = .idle
        }
        await Self.connectAndEnd(session)
        var iterator = reads.makeAsyncIterator()
        #expect(await iterator.next() == true, "one forced list read")
        let waiting = CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard())
        #expect(waiting.status == .connecting, "on its way while the list read runs, not Disconnected")
        #expect(waiting.status.linkState == .connecting)
        #expect(session.stage.failure == nil)
        let services = MachineIconTests.services()
        services.machines.add(session)
        #expect(SidebarBridge.paneUse(session.machineID, in: services.machines) == .coming,
                "a send waits for the read instead of reconnecting a machine a pause may have parked")
        answer.yield()
        for await confirming in ObservationStream({ session.linkEndRead.confirming }) where !confirming { break }
        let header = CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard())
        #expect(header.status == .pausedIdle)
        #expect(SectionHeaderRowView.statusText(header.status, hostGroup: false) == "Paused (idle)")
        #expect(SidebarBridge.paneUse(session.machineID, in: services.machines) == .stuck,
                "an open chat's reattach never undoes the pause; the page's send wakes it")
    }

    /// The forced read answers the machine still running: the link really dropped, and the header
    /// reads Disconnected (#28409), with no second forced read for the same ended link.
    @Test func anEndedLinkOnAMachineTheListSaysRunsReadsDisconnectedAfterTheRead() async {
        let session = Self.session(status: .running)
        defer { session.disconnect() }
        let (reads, read) = AsyncStream.makeStream(of: Bool.self)
        session.refresher = { force in read.yield(force) }
        await Self.connectAndEnd(session)
        var iterator = reads.makeAsyncIterator()
        #expect(await iterator.next() == true)
        for await confirming in ObservationStream({ session.linkEndRead.confirming }) where !confirming { break }
        let header = CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard())
        #expect(header.status == .disconnected)
    }

    /// A connect during the ended link's list read is the link's answer: the read no longer holds
    /// the machine as on its way, so a link that came back is not masked while the read runs.
    @Test func aConnectDuringTheListReadClearsTheConfirmation() async {
        let resolver = GateLinkResolver()
        let id = "vm-confirm-\(UUID().uuidString.prefix(8))"
        let session = CloudMachineSession(machine: CloudMachine(id: id, status: .running, displayName: "Confirm VM"),
                                          appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: resolver),
                                          localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.disconnect() }
        session.linkEndRead.confirming = true
        session.connect(origin: .user)
        var opened = resolver.opened.makeAsyncIterator()
        _ = await opened.next()
        #expect(!session.linkEndRead.confirming, "the connect is the link's answer")
        await resolver.finish()
    }

    /// The app server's `cloud.machine.connect` failed with a provider error (not a link that went
    /// down or was revoked) on a machine whose record reads running or provisioning: the machine did
    /// not start, so it reads "Failed to start", not "Disconnected".
    @Test(arguments: [CloudMachine.Status.running, .provisioning])
    func aConnectThatTheProviderFailedReadsFailedToStart(status: CloudMachine.Status) async {
        let session = Self.session(status: status, error: .failed(code: "vm_start_failed", message: "the provider could not start it"))
        defer { session.disconnect() }
        await Self.connectAndEnd(session)
        let header = CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard())
        #expect(header.status == .failed)
        #expect(SectionHeaderRowView.statusText(header.status, hostGroup: false) == "Failed to start")
    }

    /// A revoked link is a link that ended, like a drop: "Disconnected".
    @Test func aRevokedLinkReadsDisconnected() async {
        let session = Self.session(status: .running, error: .revoked(reason: "access removed"))
        defer { session.disconnect() }
        await Self.connectAndEnd(session)
        #expect(CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard()).status == .disconnected)
    }

    /// A list read began, then the person clicked Connect, and the read answered the machine
    /// paused (it was, before the click's connect started it). That stale answer must not
    /// suspend the session: the suspend would cancel the click's connect.
    @Test func aListReadThatBeganBeforeAConnectDoesNotPauseIt() async {
        let resolver = GateLinkResolver()
        let id = "vm-fence-\(UUID().uuidString.prefix(8))"
        let session = CloudMachineSession(machine: CloudMachine(id: id, status: .running, displayName: "Fenced VM"),
                                          appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: resolver),
                                          localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.disconnect() }
        let atRead = session.connects
        session.connect(origin: .user)
        var opened = resolver.opened.makeAsyncIterator()
        _ = await opened.next()
        #expect(session.linkPhase == .starting)

        var paused = session.machine
        paused.status = .paused
        paused.pauseReason = .idle
        session.listed(paused, connectsAtRead: atRead)
        #expect(session.linkPhase == .starting, "the click's connect still runs")
        #expect(session.stage == .booting, "not paused by a list that began before the click")
        await resolver.finish()
    }

    /// The same stale answer must not model the machine as paused either: the click's connect is
    /// starting it, so the header reads Connecting (live), not Offline, and keeps its running
    /// cost. The record's other fields still apply.
    @Test func aListReadThatBeganBeforeAConnectKeepsTheMachineLive() async {
        let resolver = GateLinkResolver()
        let id = "vm-fence-live-\(UUID().uuidString.prefix(8))"
        var running = CloudMachine(id: id, status: .running, displayName: "Fenced VM")
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        running.runningSince = since
        let session = CloudMachineSession(machine: running,
                                          appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: resolver),
                                          localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.disconnect() }
        let atRead = session.connects
        session.connect(origin: .user)
        var opened = resolver.opened.makeAsyncIterator()
        _ = await opened.next()

        var paused = CloudMachine(id: id, status: .paused, displayName: "Renamed VM")
        paused.pauseReason = .idle
        session.listed(paused, connectsAtRead: atRead)
        #expect(session.machine.status == .running, "the stale paused status is not taken")
        #expect(session.machine.status.isLive)
        #expect(session.machine.pauseReason == nil)
        #expect(session.machine.runningSince == since, "its running cost stays")
        #expect(session.machine.title == "Renamed VM", "the record's other fields apply")
        let header = CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard())
        #expect(header.status == .connecting, "live while the click's connect starts it, not Offline")
        await resolver.finish()
    }

    /// The provider failed the machine: "Failed to start", also when its link ended too.
    @Test func aMachineTheProviderFailedStillReadsFailedToStart() async {
        let session = Self.session(status: .failed)
        defer { session.disconnect() }
        await Self.connectAndEnd(session)
        let header = CloudCreationRows.machine(session, compatibility: nil, updates: DaemonUpdateBoard())
        #expect(header.status == .failed)
        #expect(SectionHeaderRowView.statusText(header.status, hostGroup: false) == "Failed to start")
    }
}

/// The app server's `cloud.machine.connect` for a machine whose connect fails with `error`.
private struct EndedLinkResolver: CloudLinkResolver {
    let error: CloudLinkError

    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        throw error
    }

    func close(_ key: CloudLinkKey) async {}
}

/// A `cloud.machine.connect` that answers only when the test lets it, then reports the link down.
private actor GateLinkResolver: CloudLinkResolver {
    nonisolated let opened: AsyncStream<Void>
    private nonisolated let openedSink: AsyncStream<Void>.Continuation
    private var release: CheckedContinuation<Void, Never>?
    private var finished = false

    init() {
        (opened, openedSink) = AsyncStream.makeStream(of: Void.self)
    }

    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        openedSink.yield()
        if !finished { await withCheckedContinuation { release = $0 } }
        throw CloudLinkError.disconnected(reason: "test over")
    }

    func finish() {
        finished = true
        release?.resume()
        release = nil
    }

    func close(_ key: CloudLinkKey) async {}
}
