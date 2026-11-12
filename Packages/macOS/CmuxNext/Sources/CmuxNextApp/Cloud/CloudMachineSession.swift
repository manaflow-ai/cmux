import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextWorkspaceRepair
import Foundation
import Observation
import CmuxNextWakeups

/// One Cloud machine: its record, its link, and the daemon connection over
/// the link socket. The link is the session's `carrier serve` (`appLink`, through
/// ``CloudLinkSession``), which dials the machine once per connection: after a
///   refused dial, a `cloud.link.changed` down or revoked, or a failed connect the
///   machine shows "disconnected, click to connect" (`linkEnded`).
@Observable
final class CloudMachineSession {
    let machineID: String
    var machine: CloudMachine
    /// Its create's auto-size pick, which a list read's ``machine`` lacks: a hand-off's `size`.
    var sizePick: CloudSizePick?
    let daemon: DaemonService
    @ObservationIgnored let appLink: CloudLinkSession
    /// The last Cloud start's harness login decision here: its summary for `cloud.machines`, its team skip for the chat's card.
    @ObservationIgnored var harnessLogin: CloudHarnessLoginDecision?
    /// This Mac's own daemon identity: an app link socket that leads back to
    /// it is refused after the handshake (`DaemonIdentity.checkNotLocal(local:)`, CmuxNextCloud).
    @ObservationIgnored private let localIdentity: @MainActor () -> DaemonIdentity?
    /// Why the app link ended (localized), until the next connect. Nil
    /// while connected or connecting.
    private(set) var linkEnded: String?
    /// The last ended link's error as the link gave it (``CloudAppLinks/endedMessage(_:)`` shows less), for `cloud.machines`.
    @ObservationIgnored private(set) var linkEndedDetail: String?
    /// The ended link went down or was revoked, not refused (``CloudLinkError/isDrop(_:)``).
    private(set) var linkDropped = false
    /// The list read an ended app link starts; its ``CloudLinkEndRead/confirming`` is
    /// ``CloudMachineStageInput/linkEndConfirming``, false once it answers or a connect starts.
    @ObservationIgnored let linkEndRead = CloudLinkEndRead()
    /// The link as this session's endpoint calls see it (cx-lu8f): starting,
    /// up, or the last start's failure. Drives the booting and connecting
    /// stages; never set from elapsed time.
    private(set) var linkPhase: CloudLinkPhase = .idle
    /// The ticket of the app link's live connect; nil while none is live.
    @ObservationIgnored private var appTicket: UInt64?
    /// An app-link connect hop is queued or running.
    @ObservationIgnored private var appConnecting = false
    /// A daemon update restarted the daemon while a connect hop ran: connect afresh once it ends.
    @ObservationIgnored private var reconnectAfterHop = false
    /// The machine began running while a connect was in flight: that connect is retried if it fails.
    @ObservationIgnored private var retryIfHopFails = false
    /// Counts suspends: a connect that a pause overtook opens no connection
    /// (not `isLive`: a click connects a paused machine on purpose).
    @ObservationIgnored private var suspends = 0
    /// Counts the connects this session started. A machine list read notes it
    /// when it begins (`CloudService.refresh`), so its answer can tell a
    /// connect that began after the read (``listed(_:connectsAtRead:)``).
    @ObservationIgnored private(set) var connects = 0
    @ObservationIgnored private var linkTransition: Task<Void, Never>?
    /// The app-link connect hop in flight: a pause or a disconnect cancels
    /// it instead of waiting for its link.
    @ObservationIgnored private var connectHop: Task<Void, Never>?
    /// A transition overtook a connect after its carrier answered. If that transition
    /// rolls back, reconnect the interrupted live session unless another change replaced it.
    private struct InterruptedMutation {
        let id: UUID
        var rolledBack = false
    }
    @ObservationIgnored private var interruptedMutation: InterruptedMutation?
    @ObservationIgnored private var disconnected = false
    /// Whether this session was removed permanently because its machine disappeared.
    /// A delete transition must leave this false until a list confirms removal.
    var isPermanentlyDisconnected: Bool { disconnected }
    /// Repairs an empty workspace on this machine (never on another).
    @ObservationIgnored let emptyWorkspaces: EmptyWorkspaceRepair
    /// Resumes this machine through the Resume Machine path
    /// (`CloudService.resumeMachine`), for an attach to a paused machine.
    /// Set by `CloudService`; nil where nothing resumes (some tests).
    @ObservationIgnored var resumer: (@MainActor (String, CloudLinkOrigin) async throws -> Void)?
    /// Reads the machine list again (`CloudService.refresh`); `force` false
    /// skips a list read in the last 30 seconds. Set by `CloudService`; nil in
    /// some tests. The record is read on launch and on activation, so a
    /// machine the idle auto-pause parked while cmux stayed in front can
    /// still read running here.
    @ObservationIgnored var refresher: (@MainActor (_ force: Bool) async -> Void)?
    /// A resume an attach started is in flight.
    private(set) var resuming = false
    /// Why the last attach's resume failed (localized), until the next attach.
    /// For an app link, a click's connect on a paused machine is its resume.
    private(set) var resumeFailure: String?

    /// - Parameter mainWork: The app's main-thread scheduler (the local daemon's), for the machine's event batches.
    init(machine: CloudMachine, appLink: CloudLinkSession, localIdentity: @escaping @MainActor () -> DaemonIdentity?,
         mainWork: MainWorkScheduler) {
        machineID = machine.id
        self.machine = machine
        sizePick = machine.sizePick
        self.appLink = appLink
        self.localIdentity = localIdentity
        daemon = DaemonService(machineID: machine.id, echoesPlacementShift: true, mainWork: mainWork)
        emptyWorkspaces = EmptyWorkspaceRepair(daemon: daemon)
    }

    /// Apply an authoritative record and reconcile the transport. A connection attempted while
    /// the provider was starting may fail before the VM is ready; running supplies a new retry signal.
    func applyRecord(_ record: CloudMachine) {
        let previous = machine.status
        let wasResuming = machine.pendingChange == .starting
        machine = record
        // The error may have arrived before acknowledgement, while the mutation remained
        // pending. Its settlement, not a change in displayed error text, authorizes recovery.
        if let failedMutationID = record.failedMutationID {
            mutationFailed(failedMutationID)
        }
        if !record.status.isLive, !record.shownStatus.isChanging { interruptedMutation = nil }
        switch record.edge(from: previous, wasResuming: wasResuming, connected: daemon.connection != nil) {
        case .suspend: suspend()
        case .connect: connect()
        case .retry: if appConnecting { retryIfHopFails = true } else { retryNow() }
        case nil: break
        }
        recoverInterruptedMutation()
    }

    /// Connects (a click passes origin `user`; launch and a resumed machine
    /// connect as `script`). Serializes lifecycle hops so a late pause cannot
    /// kill a resumed link. The app link connects only when it is not up: a
    /// click never drops a healthy connection, and only a click starts a
    /// paused machine (`cloud.machine.connect` starts it).
    func connect(origin: CloudLinkOrigin = .script) {
        guard !disconnected, !machine.holdsConnect(origin: origin, appLink: true) else { return }
        guard machine.status.isLive || origin == .user, !appConnecting, appTicket == nil || linkEnded != nil else { return }
        appConnecting = true
        connects += 1
        // A resume that failed earlier says nothing about this connect.
        resumeFailure = nil
        let previous = linkTransition
        // task-owner: one lifecycle hop; each later hop waits for this one
        linkTransition = Task {
            await previous?.value
            guard !disconnected, !machine.holdsConnect(origin: origin, appLink: true) else {
                noteMutationInterruption()
                appConnecting = false
                retryIfHopFails = false
                return
            }
            await connectApp(appLink, origin: origin)
        }
        connectHop = linkTransition
    }

    /// ``connect(origin:)``, then that connect's hop (or the one in flight) ends: whether the app link is up now.
    func linkHop(origin: CloudLinkOrigin) async -> Bool { connect(origin: origin); await linkTransition?.value; return linkPhase == .up && linkEnded == nil }

    /// Attaching to this machine (opening a workspace or a terminal, ssh,
    /// moving a chat here, a terminal's Connect): a paused machine resumes
    /// first through the Resume Machine path, since cmux Cloud's idle
    /// auto-pause parks idle machines, and its link connects once the record
    /// is live (`CloudService.reconcile`). A live machine's link connects (its connect starts a paused
    /// machine for a click when nothing resumes). A paused machine resumes the same way for any origin: the
    /// platform refuses a link to a paused machine (`cloud.machine.paused`), so a connect there, a person's too, failed at once.
    func attach(origin: CloudLinkOrigin = .user) {
        guard !machine.shownStatus.isChanging else { return }
        if machine.shownStatus != .paused || resumer == nil { return connect(origin: origin) }
        guard !resuming, !disconnected, let resumer else { return }
        resuming = true
        resumeFailure = nil
        // task-owner: one resume per attach; a second attach while it runs waits on it
        Task {
            defer { resuming = false }
            do {
                try await resumer(machineID, origin)
            } catch {
                guard !disconnected else { return }
                resumeFailure = CloudStrings.errorText(error)
                return
            }
            // The resume's refresh connects a record that turned live; a
            // refresh that failed leaves the record paused, so connect here.
            // Keep the raw record paused until reconciliation supplies the live record. The
            // resume mutation may still be pending, and connect() must not be blocked by a
            // synthetic running status that makes the later paused -> running edge disappear.
            if !disconnected, !machine.status.isLive { connect() }
        }
    }

    /// One app-link connect: a fresh connection on the carrier socket. The
    /// ticket ties the connection's endpoint calls and link changes to this
    /// connect, so an older connection can never end a newer one.
    private func connectApp(_ appLink: CloudLinkSession, origin: CloudLinkOrigin) async {
        defer {
            appConnecting = false
            recoverInterruptedMutation()
            let retry = retryIfHopFails && linkEnded != nil
            retryIfHopFails = false
            if retry, !reconnectAfterHop { retryNow() }
            if reconnectAfterHop {
                reconnectAfterHop = false
                appTicket = nil
                connect()
            }
        }
        appTicket = nil
        daemon.shutdownConnection()
        linkEnded = nil
        linkDropped = false
        // A new connect is this link's answer: the ended link's list read no longer holds it.
        linkEndRead.confirming = false
        resumeFailure = nil
        noteLinkStarting()
        let suspendsBefore = suspends
        let ticket: CloudLinkTicket
        do {
            ticket = try await appLink.connect(origin: origin)
        } catch {
            // A pause or a disconnect cancelled this connect: not a failure.
            if disconnected || suspends != suspendsBefore || Task.isCancelled || machine.holdsConnect(origin: origin, appLink: true) {
                noteMutationInterruption()
                await appLink.end(reason: "connect cancelled")
                linkPhase = .idle
                return
            }
            // An ended link on a paused machine reads as the pause; a failed
            // connect that was to start it says why (`CloudMachineStageInput`).
            if machine.status == .paused, origin == .user { resumeFailure = CloudAppLinks.endedMessage(error) }
            showEnded(error)
            return
        }
        if disconnected || suspends != suspendsBefore || Task.isCancelled || machine.holdsConnect(origin: origin, appLink: true) {
            // The transition overtook this connect after the carrier answered. End the
            // ticket/transport so the carrier cannot remain attached without a daemon.
            noteMutationInterruption()
            await appLink.end(reason: "connect cancelled")
            appTicket = nil
            daemon.shutdownConnection()
            linkPhase = .idle
            return
        }
        interruptedMutation = nil
        appTicket = ticket.id
        linkPhase = .up
        let localIdentity = localIdentity
        daemon.start(remote: { [weak self] in
            do {
                return try await appLink.endpoint(ticket)
            } catch {
                // The link ended: a refused carrier dial, the serve child gone, or a superseded ticket.
                let message = await self?.endAppLink(error, ticket: ticket.id) ?? String(describing: error)
                throw DaemonError.endpointBlocked(message)
            }
        }, requiredCapabilities: DaemonCapability.nativeRemoteRequired, admit: { [weak self] identity in
            do {
                try identity.checkNotLocal(local: localIdentity())
            } catch {
                self?.endAppLink(error, ticket: ticket.id)
                throw error
            }
        }, stream: {
            // An agent chat's attach and the history reader dial the same carrier: never ends the link.
            try await appLink.streamEndpoint(ticket)
        }, handshake: CloudCarrierDial.handshakeDeadline)
    }

    private func noteMutationInterruption() {
        guard !disconnected, let id = machine.pendingMutationID else { return }
        interruptedMutation = InterruptedMutation(id: id)
    }

    /// Only the operation that interrupted this connection can authorize its recovery. If
    /// another operation is still pending, keep that authorization until it settles too.
    func mutationFailed(_ id: UUID) {
        if interruptedMutation?.id == id { interruptedMutation?.rolledBack = true }
        // An unrelated rollback cannot authorize recovery, but may remove the last barrier
        // after the matching operation already rolled back while another one was pending.
        recoverInterruptedMutation()
    }

    private func recoverInterruptedMutation() {
        guard interruptedMutation?.rolledBack == true, !disconnected,
              machine.status.isLive, !machine.shownStatus.isChanging, !appConnecting else { return }
        interruptedMutation = nil
        if daemon.connection == nil { connect() }
    }

    /// The current connect's link ended: drop its connection and show why.
    /// A stale ticket (an older connect's connection) changes nothing.
    @discardableResult
    private func endAppLink(_ error: any Error, ticket: UInt64) -> String {
        let message = CloudAppLinks.endedMessage(error)
        guard !disconnected, ticket == appTicket else { return message }
        appTicket = nil
        showEnded(error)
        return message
    }

    /// "Disconnected, click to connect": no connection until the next connect.
    /// Reads the machine list again (``CloudLinkEndRead``): the idle auto-pause may have parked the
    /// machine behind the app, and the record then reads paused, not failed.
    private func showEnded(_ error: any Error) {
        CloudAppLinks.logEnded(error)
        let message = CloudAppLinks.endedMessage(error)
        linkEndedDetail = daemon.endedDetail(error)
        daemon.shutdownConnection()
        daemon.store.markFailed(message)
        linkEnded = message
        linkDropped = CloudLinkError.isDrop(error)
        linkPhase = .failed(message)
        guard let refresher else { return }
        linkEndRead.ended(dropped: linkDropped, paused: machine.status == .paused, connects: connects,
                          connectsNow: { [weak self] in self?.connects }, read: refresher)
    }

    /// A link start began. A previous start's failure stays shown until a
    /// start succeeds, so a retrying link does not flicker between the
    /// failure and booting.
    private func noteLinkStarting(since suspendsBefore: Int? = nil) {
        if let suspendsBefore, suspends != suspendsBefore { return }
        if case .failed = linkPhase { return }
        linkPhase = .starting
    }

    /// A machine list read's record for this machine (`CloudService.reconcile`):
    /// one that stopped being live suspends the session, one that turned live
    /// connects it. `connectsAtRead` is ``connects`` when the read began: a
    /// connect since then (a click's, which starts a paused machine) is newer
    /// than the answer, so a record that is not live neither suspends it nor
    /// models it paused: the session keeps its live status, pause reason and
    /// running start, and takes the record's other fields.
    func listed(_ record: CloudMachine, connectsAtRead: Int) {
        applyRecord(record.listed(over: machine, connectedSinceRead: connects != connectsAtRead))
    }

    /// Reads the record again before an attach decides, when it may be
    /// stale: a machine with no daemon connection that does not read
    /// paused (the idle auto-pause may have parked it while the app's copy
    /// still says running).
    func refreshIfMaybePaused() async {
        guard daemon.connection == nil, machine.status != .paused, !disconnected, let refresher else { return }
        await refresher(true)
    }

    // MARK: Progress (cx-lu8f)

    /// The daemon's first connect gave up with a failed attempt's text; nil
    /// while it still tries, and for a deadline with no failed attempt.
    var daemonFailure: String? {
        guard daemon.startup.isUnavailable, case .failed(let reason) = daemon.store.connectionState else { return nil }
        return reason
    }

    /// The stage inputs of this machine's link and daemon.
    var stageInput: CloudMachineStageInput {
        var connected = false
        if case .connected = daemon.store.connectionState { connected = daemon.connection != nil }
        return CloudMachineStageInput(creation: nil, machineStatus: machine.shownStatus, link: linkPhase, daemonConnected: connected,
                                      daemonLoaded: daemon.store.isLoaded, daemonFailure: daemonFailure, linkEnded: linkEnded,
                                      pauseReason: machine.pauseReason, resuming: resuming, resumeFailure: resumeFailure, changeFailure: machine.lastChangeFailure?.text,
                                      linkDropped: linkDropped, linkEndConfirming: linkEndRead.confirming)
    }

    /// Where the machine is on its way to a usable daemon.
    var stage: CloudMachineStage { stageInput.stage }

    /// The machine's status as the person sees it: the API record, except
    /// that a connected daemon is a running machine. A create response has
    /// no status (decoded as provisioning) and the list is not polled, so the
    /// record alone said "provisioning" after the terminal worked.
    var effectiveStatus: CloudMachine.Status {
        guard machine.shownStatus == .provisioning || machine.shownStatus == .unknown, case .connected = daemon.store.connectionState else {
            return machine.shownStatus
        }
        return .running
    }

    /// Retry after a failure (the progress view's Retry or Resume, a user gesture): the record is read first (the idle
    /// auto-pause may have parked the machine behind it), then a paused machine resumes (``attach(origin:)``) or an ended
    /// app link connects again.
    func retry() {
        guard daemon.connection == nil, machine.status != .paused, refresher != nil else { return retryNow() }
        // task-owner: one list read before the retry; the retry itself is synchronous
        Task {
            await refreshIfMaybePaused()
            retryNow()
        }
    }

    /// A start's or a move's wait: true once the daemon answers or a resume failed; a paused machine resumes once, an ended link redials.
    func linkUp(within limit: Duration) async -> Bool {
        let beats = CloudWait.StartRedials() // what each beat does is Rust's (`start_redial`)
        return await CloudWait.holds(within: limit, redialing: CloudWait.startRedial, redial: {
            beats.beat(ended: linkEnded != nil && !appConnecting, status: machine.status, resume: { attach(origin: .script) }, connect: { connect() })
        }) { [daemon] in
            self.resumeFailure != nil || (daemon.connection != nil && AgentTabStore.registryHost(of: daemon) != nil)
        }
    }

    /// The link a wait brought up holds: a live daemon and no failed resume (``linkUp(within:)`` also ends on one).
    func linkHeld() -> Bool { resumeFailure == nil && daemon.connection != nil }

    /// Retry on the record as it stands (the caller just read it): connect the link again, or resume a paused app-link machine first (``attach(origin:)``; the platform refuses its link).
    func retryNow() {
        if case .failed = linkPhase { linkPhase = .starting }
        if machine.shownStatus == .paused, resumer != nil { attach() } else { connect(origin: .user) }
    }

    /// After `cmux link machine update` ran here (``CloudMachineUpdates``): connect to the daemon
    /// it left (``CloudLinkAfterUpdate``).
    func reconnectAfterUpdate(restarted: Bool) {
        switch CloudLinkAfterUpdate(restarted: restarted, linkEnded: linkEnded != nil, connected: daemon.connection != nil,
                                    connecting: appConnecting) {
        case .connect(let dropTicket):
            if dropTicket { appTicket = nil }
            connect()
        case .connectAfterHop:
            appTicket = nil
            reconnectAfterHop = true
        }
    }

    /// A `cloud.link.changed` for this machine.
    func linkChanged(_ change: CloudLinkChange) {
        // task-owner: one actor hop; a link that already ended ignores it
        Task {
            guard let ended = await appLink.apply(change) else { return }
            let reason = change.reason ?? change.state.rawValue
            endAppLink(change.state == .revoked ? CloudLinkError.revoked(reason: reason) : CloudLinkError.disconnected(reason: reason),
                       ticket: ended)
        }
    }

    func disconnect() {
        disconnected = true
        linkPhase = .idle
        connectHop?.cancel()
        daemon.shutdownConnection()
        let previous = linkTransition
        let appLink = appLink
        // task-owner: terminal teardown after earlier lifecycle hops
        linkTransition = Task {
            await previous?.value
            await appLink.close()
        }
    }

    /// Keeps a session reusable while an accepted delete is still settling. The provider can
    /// reject the delete after the server has acknowledged it, in which case the next machine
    /// list must be able to reconnect this same session when it returns to running.
    func retainForDeleteTransition() {
        machine.status = .deleting
        suspend()
    }

    /// Drops the daemon connection, keeping the link reusable, after a provider pause/resume transition, or
    /// (`pausing`) as soon as the server took a person's pause, which a rollback then reconnects (mutationFailed).
    func suspend(pausing: Bool = false) {
        suspends += 1
        if pausing { noteMutationInterruption() }
        // A new pause: an earlier resume's failure no longer applies.
        resumeFailure = nil
        connectHop?.cancel()
        (appTicket, linkPhase) = (nil, .idle)
        daemon.shutdownConnection()
        let previous = linkTransition
        let appLink = appLink
        // task-owner: reversible teardown (the serve stops, so nothing wakes the machine); resume waits for this hop
        linkTransition = Task {
            await previous?.value
            await appLink.park(reason: "paused")
        }
    }
}
