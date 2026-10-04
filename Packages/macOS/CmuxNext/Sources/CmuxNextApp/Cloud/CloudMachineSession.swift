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
    /// Why the app link ended (localized), until the next connect. Nil
    /// while connected or connecting, and always nil for the legacy link.
    private(set) var linkEnded: String?
    @ObservationIgnored private var linkTransition: Task<Void, Never>?
    @ObservationIgnored private var disconnected = false
    /// Repairs an empty workspace on this machine (never on another).
    @ObservationIgnored private(set) var emptyWorkspaces: EmptyWorkspaceRepair!

    convenience init(machine: CloudMachine, link: CloudMachineLink) {
        self.init(machine: machine, link: link, appLink: nil)
    }

    convenience init(machine: CloudMachine, appLink: CloudLinkSession) {
        self.init(machine: machine, link: nil, appLink: appLink)
    }

    private init(machine: CloudMachine, link: CloudMachineLink?, appLink: CloudLinkSession?) {
        machineID = machine.id
        self.machine = machine
        self.link = link
        self.appLink = appLink
        daemon = DaemonService(machineID: machine.id)
        emptyWorkspaces = EmptyWorkspaceRepair(daemon: daemon)
    }

    /// Connects (a click passes origin `user`; launch and a resumed machine
    /// connect as `script`). Serializes lifecycle hops so a late pause cannot
    /// kill a resumed link.
    func connect(origin: CloudLinkOrigin = .script) {
        guard !disconnected, machine.status.isLive else { return }
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
            daemon.start(remote: { try await link.socketPath() })
        }
    }

    /// One app-link connect: a fresh connection on the carrier socket.
    private func connectApp(_ appLink: CloudLinkSession, origin: CloudLinkOrigin) async {
        daemon.shutdownConnection()
        linkEnded = nil
        do {
            try await appLink.connect(origin: origin)
        } catch {
            // A connect superseded by a later hop is not this session's end.
            guard !disconnected, await appLink.isEnded else { return }
            endAppLink(error)
            return
        }
        guard !disconnected, machine.status.isLive else { return }
        daemon.start(remote: { [weak self] in
            do {
                return try await appLink.endpoint()
            } catch {
                // The connection asked again: it dropped. v1 waits for a click.
                let message = await self?.endAppLink(error) ?? String(describing: error)
                throw DaemonError.endpointBlocked(message)
            }
        })
    }

    /// The app link ended: drop its connection and show why.
    @discardableResult
    private func endAppLink(_ error: any Error) -> String {
        let message = CloudAppLinks.endedMessage(error)
        guard !disconnected else { return message }
        daemon.shutdownConnection()
        daemon.store.markFailed(message)
        linkEnded = message
        return message
    }

    /// A `cloud.link.changed` for this machine (app link only).
    func linkChanged(_ change: CloudLinkChange) {
        guard let appLink else { return }
        // task-owner: one actor hop; a link that already ended ignores it
        Task {
            guard await appLink.apply(change) else { return }
            let reason = change.reason ?? change.state.rawValue
            endAppLink(change.state == .revoked ? CloudLinkError.revoked(reason: reason) : CloudLinkError.disconnected(reason: reason))
        }
    }

    func disconnect() {
        disconnected = true
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
