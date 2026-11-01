import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextWorkspaceRepair
import Foundation
import Observation
import CmuxNextWakeups

/// One Cloud machine: its `/api/vm` record, its link, and the daemon
/// connection over the link socket. The link is one of two sources:
/// - `link`: the frozen `/api/vm` attach endpoint and a `cmux-tui remote
///   connect` process (contract 2.5; deleted when 2.3 works), which
///   reconnects by itself;
/// - `appLink`: the Cloud app server's link through ``CloudLinkSession``
///   (contract 2.3), whose socket serves one connection per connect: after a
///   drop, a `cloud.link.changed` down or revoked, or a failed connect the
///   machine shows "disconnected, click to connect" (`linkEnded`).
@Observable
final class CloudMachineSession {
    let machineID: String
    var machine: CloudMachine
    /// Its create's auto-size pick, which a list read's ``machine`` lacks: a hand-off's `size`.
    var sizePick: CloudSizePick?
    let daemon: DaemonService
    @ObservationIgnored let link: CloudMachineLink?
    @ObservationIgnored let appLink: CloudLinkSession?
    /// The last Cloud start's harness login decision here: its summary for `cloud.machines`, its team skip for the chat's card.
    @ObservationIgnored var harnessLogin: CloudHarnessLoginDecision?
    /// This Mac's own daemon identity: an app link socket that leads back to
    /// it is refused after the handshake (`CloudAppLinks.checkNotLocal`).
    @ObservationIgnored private let localIdentity: @MainActor () -> DaemonIdentity?
    /// Why the app link ended (localized), until the next connect. Nil
    /// while connected or connecting, and always nil for the legacy link.
    private(set) var linkEnded: String?
    /// The ended link went down or was revoked, not refused (``CloudAppLinks/isDrop(_:)``).
    private(set) var linkDropped = false
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
    /// Counts suspends: a connect that a pause overtook opens no connection
    /// (not `isLive`: a click connects a paused machine on purpose).
    @ObservationIgnored private var suspends = 0
    /// Counts the connects this session started. A machine list read notes it
    /// when it begins (`CloudService.refresh`), so its answer can tell a
    /// connect that began after the read (``listed(_:connectsAtRead:)``).
    @ObservationIgnored private(set) var connects = 0
    @ObservationIgnored private var linkTransition: Task<Void, Never>?
    /// The app-link connect hop in flight: a pause or a disconnect cancels
    /// it instead of waiting up to `CloudAppLinks.connectTimeout`.
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
    @ObservationIgnored var resumer: (@MainActor (String) async throws -> Void)?
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
    convenience init(machine: CloudMachine, link: CloudMachineLink, mainWork: MainWorkScheduler) {
        self.init(machine: machine, link: link, appLink: nil, localIdentity: { nil }, mainWork: mainWork)
    }

    /// - Parameter mainWork: The app's main-thread scheduler (the local daemon's), for the machine's event batches.
    convenience init(machine: CloudMachine, appLink: CloudLinkSession, localIdentity: @escaping @MainActor () -> DaemonIdentity?,
                     mainWork: MainWorkScheduler) {
        self.init(machine: machine, link: nil, appLink: appLink, localIdentity: localIdentity, mainWork: mainWork)
    }

    private init(machine: CloudMachine, link: CloudMachineLink?, appLink: CloudLinkSession?,
                 localIdentity: @escaping @MainActor () -> DaemonIdentity?, mainWork: MainWorkScheduler) {
        machineID = machine.id
        self.machine = machine
        sizePick = machine.sizePick
        self.link = link
        self.appLink = appLink
        self.localIdentity = localIdentity
        daemon = DaemonService(machineID: machine.id, echoesPlacementShift: SidebarMirror.isLinked, mainWork: mainWork)
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
        if previous.isLive, !record.status.isLive {
            suspend()
        } else if !previous.isLive, record.status.isLive {
            connect()
        } else if wasResuming, record.pendingChange == nil, record.status.isLive, daemon.connection == nil {
            // A read can report running while the resume request still awaits acknowledgement.
            // That read cannot connect through the pending overlay. Clearing it is a second
            // live edge even when the raw status already reads running.
            connect()
        } else if previous == .starting, record.status == .running, daemon.connection == nil {
            retryNow()
        }
        recoverInterruptedMutation()
    }

    /// Connects (a click passes origin `user`; launch and a resumed machine
    /// connect as `script`). Serializes lifecycle hops so a late pause cannot
    /// kill a resumed link. An app link connects only when it is not up: a
    /// click never drops a healthy connection, and only a click starts a
    /// paused machine (`cloud.machine.connect` starts it).
    func connect(origin: CloudLinkOrigin = .script) {
        guard !disconnected, !machine.shownStatus.isChanging else { return }
        if appLink != nil {
            guard machine.status.isLive || origin == .user, !appConnecting, appTicket == nil || linkEnded != nil else { return }
            appConnecting = true
        } else {
            guard machine.status.isLive else { return }
        }
        connects += 1
        // A resume that failed earlier says nothing about this connect.
        resumeFailure = nil
        let previous = linkTransition
        // task-owner: one lifecycle hop; each later hop waits for this one
        linkTransition = Task {
            await previous?.value
            guard !disconnected, !machine.shownStatus.isChanging else {
                noteMutationInterruption()
                appConnecting = false
                return
            }
            if let appLink {
                await connectApp(appLink, origin: origin)
                return
            }
            guard let link else { return }
            await link.resume()
            guard !disconnected, machine.status.isLive, !machine.shownStatus.isChanging else {
                noteMutationInterruption()
                return
            }
            // A link start that a pause overtook changes nothing (`noteLink`).
            let suspendsBefore = suspends
            daemon.start(remote: { [weak self] in
                await self?.noteLinkStarting(since: suspendsBefore)
                do {
                    let path = try await link.socketPath()
                    await self?.noteLink(.up, since: suspendsBefore)
                    return path
                } catch {
                    if !(error is CancellationError) { await self?.noteLink(.failed(CloudStrings.errorText(error)), since: suspendsBefore) }
                    throw error
                }
            })
        }
        if appLink != nil { connectHop = linkTransition }
    }

    /// Attaching to this machine (opening a workspace or a terminal, ssh,
    /// moving a chat here, a terminal's Connect): a paused machine resumes
    /// first through the Resume Machine path, since cmux Cloud's idle
    /// auto-pause parks idle machines, and its link connects once the record
    /// is live (`CloudService.reconcile`). An app link connects as before
    /// (its connect starts a paused machine for a click); a live legacy link
    /// reconnects by itself, so nothing else changes.
    func attach(origin: CloudLinkOrigin = .user) {
        guard !machine.shownStatus.isChanging else { return }
        if appLink != nil { return connect(origin: origin) }
        guard machine.shownStatus == .paused, !resuming, !disconnected, let resumer else { return }
        resuming = true
        resumeFailure = nil
        // task-owner: one resume per attach; a second attach while it runs waits on it
        Task {
            defer { resuming = false }
            do {
                try await resumer(machineID)
            } catch {
                guard !disconnected else { return }
                resumeFailure = CloudStrings.errorText(error)
                return
            }
            // The resume's refresh connects a record that turned live; a
            // refresh that failed leaves the record paused, so connect here.
            guard !disconnected, !machine.status.isLive else { return }
            // Keep the raw record paused until reconciliation supplies the live record. The
            // resume mutation may still be pending, and connect() must not be blocked by a
            // synthetic running status that makes the later paused -> running edge disappear.
            connect()
        }
    }

    /// One app-link connect: a fresh connection on the carrier socket. The
    /// ticket ties the connection's endpoint calls and link changes to this
    /// connect, so an older connection can never end a newer one.
    private func connectApp(_ appLink: CloudLinkSession, origin: CloudLinkOrigin) async {
        defer {
            appConnecting = false
            recoverInterruptedMutation()
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
        resumeFailure = nil
        noteLinkStarting()
        let suspendsBefore = suspends
        let ticket: CloudLinkTicket
        do {
            ticket = try await appLink.connect(origin: origin)
        } catch {
            // A pause or a disconnect cancelled this connect: not a failure.
            if disconnected || suspends != suspendsBefore || Task.isCancelled || machine.shownStatus.isChanging {
                noteMutationInterruption()
                await appLink.end(reason: "connect cancelled")
                linkPhase = .idle
                return
            }
            // An ended link on a paused machine reads as the pause; a failed
            // connect that was to start it says why (`CloudMachineStageInput`).
            if machine.status == .paused { resumeFailure = CloudAppLinks.endedMessage(error) }
            showEnded(error)
            return
        }
        if disconnected || suspends != suspendsBefore || Task.isCancelled || machine.shownStatus.isChanging {
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
                // The connection asked again: it dropped. v1 waits for a click.
                let message = await self?.endAppLink(error, ticket: ticket.id) ?? String(describing: error)
                throw DaemonError.endpointBlocked(message)
            }
        }, admit: { [weak self] identity in
            do {
                try CloudAppLinks.checkNotLocal(remote: identity, local: localIdentity())
            } catch {
                self?.endAppLink(error, ticket: ticket.id)
                throw error
            }
        })
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
    /// Reads the machine list again (at most every 30 s), as a legacy link's
    /// failure does (`noteLink`): the idle auto-pause may have parked the
    /// machine behind the app, and the record then reads paused, not failed.
    private func showEnded(_ error: any Error) {
        CloudAppLinks.logEnded(error)
        let message = CloudAppLinks.endedMessage(error)
        daemon.shutdownConnection()
        daemon.store.markFailed(message)
        linkEnded = message
        linkDropped = CloudAppLinks.isDrop(error)
        linkPhase = .failed(message)
        if let refresher {
            // task-owner: one throttled list read; the reconcile it runs updates this record
            Task { await refresher(false) }
        }
    }

    /// A link start began. A previous start's failure stays shown until a
    /// start succeeds, so a retrying link does not flicker between the
    /// failure and booting.
    private func noteLinkStarting(since suspendsBefore: Int? = nil) {
        if let suspendsBefore, suspends != suspendsBefore { return }
        if case .failed = linkPhase { return }
        linkPhase = .starting
    }

    /// A legacy link start's outcome. One that a pause overtook (`suspends`
    /// moved since it began) changes nothing, so a late failure cannot turn
    /// a paused machine into Failed. A failure reads the machine list again
    /// (at most every 30 s): the machine may have been paused behind the app.
    private func noteLink(_ phase: CloudLinkPhase, since suspendsBefore: Int) {
        guard !disconnected, suspends == suspendsBefore else { return }
        linkPhase = phase
        if case .failed = phase, let refresher {
            // task-owner: one throttled list read; the reconcile it runs updates this record
            Task { await refresher(false) }
        }
    }

    /// A machine list read's record for this machine (`CloudService.reconcile`):
    /// one that stopped being live suspends the session, one that turned live
    /// connects it. `connectsAtRead` is ``connects`` when the read began: a
    /// connect since then (a click's, which starts a paused machine) is newer
    /// than the answer, so a record that is not live neither suspends it nor
    /// models it paused: the session keeps its live status, pause reason and
    /// running start, and takes the record's other fields.
    func listed(_ record: CloudMachine, connectsAtRead: Int) {
        var accepted = record
        if machine.status.isLive, !record.status.isLive, connects != connectsAtRead {
            (accepted.status, accepted.pauseReason, accepted.runningSince) = (machine.status, machine.pauseReason, machine.runningSince)
        }
        applyRecord(accepted)
    }

    /// Reads the record again before an attach decides, when it may be
    /// stale: a legacy machine with no daemon connection that does not read
    /// paused (the idle auto-pause may have parked it while the app's copy
    /// still says running).
    func refreshIfMaybePaused() async {
        guard appLink == nil, daemon.connection == nil, machine.status != .paused, !disconnected, let refresher else { return }
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
                                      linkDropped: linkDropped)
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

    /// Retry after a failure (the progress view's Retry or Resume, a user
    /// gesture): a paused legacy machine resumes (``attach(origin:)``); an
    /// ended app link connects again; a legacy link's daemon retries now
    /// instead of waiting for its next wake.
    func retry() {
        if appLink == nil, daemon.connection == nil, machine.status != .paused, refresher != nil {
            // The record may be stale: read it, then retry on what it says.
            // task-owner: one list read before the retry; the retry itself is synchronous
            Task {
                await refreshIfMaybePaused()
                retryNow()
            }
            return
        }
        retryNow()
    }

    /// Retry on the record as it stands (the caller just read it): resume a paused legacy machine,
    /// else connect an app link, wake a legacy daemon that is starting, or connect it again.
    func retryNow() {
        if appLink == nil, machine.status == .paused { return attach(origin: .user) }
        if case .failed = linkPhase { linkPhase = .starting }
        if appLink != nil {
            connect(origin: .user)
        } else if daemon.isStarting {
            daemon.retryWake.fire()
        } else {
            connect(origin: .user)
        }
    }

    /// After `cmux link machine update` ran here (``CloudMachineUpdates``): connect to the daemon
    /// it left. A legacy link's waiting connect is woken. An app link: ``afterUpdate(restarted:linkEnded:connected:connecting:)``.
    func reconnectAfterUpdate(restarted: Bool) {
        guard appLink != nil else { return daemon.retryWake.fire() }
        switch Self.afterUpdate(restarted: restarted, linkEnded: linkEnded != nil, connected: daemon.connection != nil,
                                connecting: appConnecting) {
        case .connect(let dropTicket):
            if dropTicket { appTicket = nil }
            connect()
        case .connectAfterHop:
            appTicket = nil
            reconnectAfterHop = true
        }
    }

    /// What an app link does after an update.
    nonisolated enum AfterUpdate: Equatable, Sendable {
        /// Connect; `dropTicket` first lets it run over the current connect's ticket.
        case connect(dropTicket: Bool)
        /// A connect hop runs (maybe to the old daemon): connect afresh once it ends.
        case connectAfterHop
    }

    /// The daemon may have restarted (`restarted`): a connection the app still holds is to the old
    /// daemon, and its drop may reach the app after the CLI answered (each has its own carrier
    /// connection). Its ticket goes now, so that late drop is an old ticket's and changes nothing,
    /// and a fresh connect runs (after a hop in flight). Nothing restarted: a healthy connection
    /// stays (a connect with a live ticket does nothing); an ended link connects again, and so does
    /// a refused daemon's (no connection): that connect waits for an event, and its next ask of the
    /// socket would only end the link.
    nonisolated static func afterUpdate(restarted: Bool, linkEnded: Bool, connected: Bool, connecting: Bool) -> AfterUpdate {
        if restarted { return connecting ? .connectAfterHop : .connect(dropTicket: true) }
        return .connect(dropTicket: !linkEnded && !connected && !connecting)
    }

    /// A `cloud.link.changed` for this machine (app link only).
    func linkChanged(_ change: CloudLinkChange) {
        guard let appLink else { return }
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
        let link = link, appLink = appLink
        // task-owner: terminal teardown after earlier lifecycle hops
        linkTransition = Task {
            await previous?.value
            await link?.stop()
            await appLink?.close()
        }
    }

    /// Keeps a session reusable while an accepted delete is still settling. The provider can
    /// reject the delete after the server has acknowledged it, in which case the next machine
    /// list must be able to reconnect this same session when it returns to running.
    func retainForDeleteTransition() {
        machine.status = .deleting
        suspend()
    }

    /// Drops the daemon connection while keeping the link reusable after a
    /// provider pause/resume transition.
    func suspend() {
        suspends += 1
        // A new pause: an earlier resume's failure no longer applies.
        resumeFailure = nil
        connectHop?.cancel()
        appTicket = nil
        linkPhase = .idle
        daemon.shutdownConnection()
        let previous = linkTransition
        let link = link, appLink = appLink
        // task-owner: reversible teardown; resume waits for this hop
        linkTransition = Task {
            await previous?.value
            await link?.suspend()
            await appLink?.end(reason: "paused")
        }
    }
}

extension CloudMachineSession {
    /// Wakes this machine for a Cloud space (a paused machine resumes, an ended link connects) and returns once its
    /// daemon is connected. A failed resume ends the wait at once with its reason; the bound is `CloudMove`'s.
    func connectedForSpace() async throws {
        // A machine the person disconnected stays so until they connect it (its menu's Connect): no wait for it.
        if disconnected { throw ActionFailure(message: CloudStrings.notConnected) }
        // A failure left from an earlier attempt must not end this wait before this attempt's own resume runs.
        resumeFailure = nil
        if daemon.connection == nil {
            await refreshIfMaybePaused()
            if machine.status == .paused { attach(origin: .user) } else { connect(origin: .user) }
        }
        let daemon = daemon
        guard await CloudMove.holds(within: .seconds(180), until: { [weak self] in
            self?.resumeFailure != nil || daemon.connection != nil
        }) else { throw DaemonError.notConnected }
        if let failure = resumeFailure { throw ActionFailure(message: failure) }
    }
}
