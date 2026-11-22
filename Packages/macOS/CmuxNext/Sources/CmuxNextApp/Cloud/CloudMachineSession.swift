import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Observation

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

    convenience init(machine: CloudMachine, link: CloudMachineLink) {
        self.init(machine: machine, link: link, appLink: nil, localIdentity: { nil })
    }

    convenience init(machine: CloudMachine, appLink: CloudLinkSession, localIdentity: @escaping @MainActor () -> DaemonIdentity?) {
        self.init(machine: machine, link: nil, appLink: appLink, localIdentity: localIdentity)
    }

    private init(machine: CloudMachine, link: CloudMachineLink?, appLink: CloudLinkSession?,
                 localIdentity: @escaping @MainActor () -> DaemonIdentity?) {
        machineID = machine.id
        self.machine = machine
        self.link = link
        self.appLink = appLink
        self.localIdentity = localIdentity
        daemon = DaemonService(machineID: machine.id)
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
            daemon.start(remote: { [weak self] in
                await self?.noteLinkStarting()
                do {
                    let path = try await link.socketPath()
                    await self?.noteLink(.up)
                    return path
                } catch {
                    if !(error is CancellationError) { await self?.noteLink(.failed(String(describing: error))) }
                    throw error
                }
            })
        }
        if appLink != nil { connectHop = linkTransition }
    }

    /// One app-link connect: a fresh connection on the carrier socket. The
    /// ticket ties the connection's endpoint calls and link changes to this
    /// connect, so an older connection can never end a newer one.
    private func connectApp(_ appLink: CloudLinkSession, origin: CloudLinkOrigin) async {
        defer { appConnecting = false }
        appTicket = nil
        daemon.shutdownConnection()
        linkEnded = nil
        noteLinkStarting()
        let suspendsBefore = suspends
        let ticket: CloudLinkTicket
        do {
            ticket = try await appLink.connect(origin: origin)
        } catch {
            // A pause or a disconnect cancelled this connect: not a failure.
            guard !disconnected, suspends == suspendsBefore, !Task.isCancelled else { return }
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
        let message = CloudAppLinks.endedMessage(error)
        daemon.shutdownConnection()
        daemon.store.markFailed(message)
        linkEnded = message
        linkPhase = .failed(message)
    }

    /// A link start began. A previous start's failure stays shown until a
    /// start succeeds, so a retrying link does not flicker between the
    /// failure and booting.
    private func noteLinkStarting() {
        if case .failed = linkPhase { return }
        linkPhase = .starting
    }

    private func noteLink(_ phase: CloudLinkPhase) {
        guard !disconnected else { return }
        linkPhase = phase
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
                                      daemonLoaded: daemon.store.isLoaded, daemonFailure: daemonFailure, linkEnded: linkEnded)
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

    /// Retry after a failure (the progress view's Retry, a user gesture): an
    /// ended app link connects again; a legacy link's daemon retries now
    /// instead of waiting for its next wake.
    func retry() {
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
