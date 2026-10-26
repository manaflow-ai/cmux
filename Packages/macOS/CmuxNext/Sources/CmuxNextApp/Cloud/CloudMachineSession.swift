import CmuxNextCloud
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
    let daemon: DaemonService
    @ObservationIgnored let link: CloudMachineLink?
    @ObservationIgnored let appLink: CloudLinkSession?
    /// This Mac's own daemon identity: an app link socket that leads back to
    /// it is refused after the handshake (`CloudAppLinks.checkNotLocal`).
    @ObservationIgnored private let localIdentity: @MainActor () -> DaemonIdentity?
    /// Why the app link ended (localized), until the next connect. Nil
    /// while connected or connecting, and always nil for the legacy link.
    private(set) var linkEnded: String?
    /// The link as this session's endpoint calls see it (cx-lu8f): starting,
    /// up, or the last start's failure. Drives the booting and connecting
    /// stages; never set from elapsed time.
    private(set) var linkPhase: CloudLinkPhase = .idle
    /// The ticket of the app link's live connect; nil while none is live.
    @ObservationIgnored private var appTicket: UInt64?
    /// An app-link connect hop is queued or running.
    @ObservationIgnored private var appConnecting = false
    /// Counts suspends: a connect that a pause overtook opens no connection
    /// (not `isLive`: a click connects a paused machine on purpose).
    @ObservationIgnored private var suspends = 0
    @ObservationIgnored private var linkTransition: Task<Void, Never>?
    /// The app-link connect hop in flight: a pause or a disconnect cancels
    /// it instead of waiting up to `CloudAppLinks.connectTimeout`.
    @ObservationIgnored private var connectHop: Task<Void, Never>?
    @ObservationIgnored private var disconnected = false
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
        self.link = link
        self.appLink = appLink
        self.localIdentity = localIdentity
        daemon = DaemonService(machineID: machine.id, echoesPlacementShift: SidebarMirror.isLinked, mainWork: mainWork)
        emptyWorkspaces = EmptyWorkspaceRepair(daemon: daemon)
    }

    /// Connects (a click passes origin `user`; launch and a resumed machine
    /// connect as `script`). Serializes lifecycle hops so a late pause cannot
    /// kill a resumed link. An app link connects only when it is not up: a
    /// click never drops a healthy connection, and only a click starts a
    /// paused machine (`cloud.machine.connect` starts it).
    func connect(origin: CloudLinkOrigin = .script) {
        guard !disconnected else { return }
        if appLink != nil {
            guard machine.status.isLive || origin == .user, !appConnecting, appTicket == nil || linkEnded != nil else { return }
            appConnecting = true
        } else {
            guard machine.status.isLive else { return }
        }
        // A resume that failed earlier says nothing about this connect.
        resumeFailure = nil
        let previous = linkTransition
        // task-owner: one lifecycle hop; each later hop waits for this one
        linkTransition = Task {
            await previous?.value
            if let appLink {
                await connectApp(appLink, origin: origin)
                return
            }
            guard let link else { return }
            await link.resume()
            guard !disconnected, machine.status.isLive else { return }
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
        if appLink != nil { return connect(origin: origin) }
        guard machine.status == .paused, !resuming, !disconnected, let resumer else { return }
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
            machine.status = .running
            connect()
        }
    }

    /// One app-link connect: a fresh connection on the carrier socket. The
    /// ticket ties the connection's endpoint calls and link changes to this
    /// connect, so an older connection can never end a newer one.
    private func connectApp(_ appLink: CloudLinkSession, origin: CloudLinkOrigin) async {
        defer { appConnecting = false }
        appTicket = nil
        daemon.shutdownConnection()
        linkEnded = nil
        resumeFailure = nil
        noteLinkStarting()
        let suspendsBefore = suspends
        let ticket: CloudLinkTicket
        do {
            ticket = try await appLink.connect(origin: origin)
        } catch {
            // A pause or a disconnect cancelled this connect: not a failure.
            guard !disconnected, suspends == suspendsBefore, !Task.isCancelled else { return }
            // An ended link on a paused machine reads as the pause; a failed
            // connect that was to start it says why (`CloudMachineStageInput`).
            if machine.status == .paused { resumeFailure = CloudAppLinks.endedMessage(error) }
            showEnded(error)
            return
        }
        guard !disconnected, suspends == suspendsBefore, !Task.isCancelled else { return }
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
    private func showEnded(_ error: any Error) {
        CloudAppLinks.logEnded(error)
        let message = CloudAppLinks.endedMessage(error)
        daemon.shutdownConnection()
        daemon.store.markFailed(message)
        linkEnded = message
        linkPhase = .failed(message)
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
        return CloudMachineStageInput(creation: nil, machineStatus: machine.status, link: linkPhase, daemonConnected: connected,
                                      daemonLoaded: daemon.store.isLoaded, daemonFailure: daemonFailure, linkEnded: linkEnded,
                                      pauseReason: machine.pauseReason, resuming: resuming, resumeFailure: resumeFailure)
    }

    /// Where the machine is on its way to a usable daemon.
    var stage: CloudMachineStage { stageInput.stage }

    /// The machine's status as the person sees it: the API record, except
    /// that a connected daemon is a running machine. A create response has
    /// no status (decoded as provisioning) and the list is not polled, so the
    /// record alone said "provisioning" after the terminal worked.
    var effectiveStatus: CloudMachine.Status {
        guard machine.status == .provisioning || machine.status == .unknown, case .connected = daemon.store.connectionState else {
            return machine.status
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

    private func retryNow() {
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
