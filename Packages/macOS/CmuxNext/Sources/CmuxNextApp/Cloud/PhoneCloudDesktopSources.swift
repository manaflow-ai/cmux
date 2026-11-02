import CmuxNextCompat
import CmuxNextMobile
import CmuxNextPhone
import CmuxNextRemoteViewSessions
import Foundation
import os

/// The phone's view-only Cloud desktops (the Chief info page's Computer card, cmux issue 31488):
/// one ``CloudDesktopSurfaceServer`` per hostd surface tab `c~<machine_id>~<team_id>`, with frames
/// from the machine's VNC desktop over this Mac's Cloud tunnel (``CloudDesktopFrames``). A source
/// starts only for a current, owned, running machine of the signed-in account (hostd checks the
/// same before it asks), and stops when the account changes, the machine leaves the list or stops
/// running, its desktop stream ends, or hostd stops it.
@MainActor
final class PhoneCloudDesktopSources {
    nonisolated struct Target: Equatable, Sendable {
        let machine: String
        let team: String
    }

    nonisolated enum Failure: Error, Sendable, CustomStringConvertible {
        case notCloudDesktop, forbidden, asleep, unreachable

        var description: String {
            switch self {
            case .notCloudDesktop: "that tab is not a Cloud desktop"
            case .forbidden: "that Cloud machine is not this account's own"
            case .asleep: "that Cloud machine is not running"
            case .unreachable: "this Mac cannot reach that Cloud machine's desktop"
            }
        }
    }

    /// The `c~<machine_id>~<team_id>` tab of a Cloud desktop; nil for anything else (`~` is never in a Cloud id).
    nonisolated static func target(of tab: String) -> Target? {
        let parts = tab.split(separator: "~", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "c", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return Target(machine: String(parts[1]), team: String(parts[2]))
    }

    private weak var services: AppServices?
    private var running: [String: (server: CloudDesktopSurfaceServer, watch: Task<Void, Never>)] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "phone.surface")

    init(services: AppServices) {
        self.services = services
    }

    func start(tab: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
        guard let target = Self.target(of: tab) else { throw Failure.notCloudDesktop }
        guard let services, let user = services.cloud.auth.user?.id else { throw Failure.forbidden }
        let team = services.cloud.auth.teamID
        // The same trust check as hostd's: exactly one owned link of this machine and team.
        let matches = await services.phoneCloudLinks().links.filter { $0.machineID == target.machine && $0.teamID == target.team }
        guard matches.count == 1, let link = matches.first, link.owner else { throw Failure.forbidden }
        // The account may have changed during the hop; the session must still be the listed one.
        guard services.cloud.auth.isSignedIn, services.cloud.auth.user?.id == user, services.cloud.auth.teamID == team,
              let session = services.machines.session(link.machineID) else { throw Failure.forbidden }
        guard session.machine.shownStatus == .running else { throw Failure.asleep }
        guard let open = services.cloudDesktopTransport(machine: session.machineID) else { throw Failure.unreachable }

        stop(tab: tab)
        let frames = CloudDesktopFrames(machine: session.machineID, open: open)
        let server = CloudDesktopSurfaceServer(feed: SurfaceFrameFeed(start: { frames.start(frame: $0, ended: $1) },
                                                                      stop: { frames.stop() }),
                                               label: session.machineID)
        server.onEnd = { [weak self, weak server] in
            if let server, let entry = self?.running[tab], entry.server === server {
                entry.watch.cancel()
                self?.running[tab] = nil
            }
            onExit()
        }
        // Ends the source the moment the machine stops running here or the account changes.
        let machines = services.machines, cloud = services.cloud
        let live = ObservationStream { [weak session] in
            guard let session else { return false }
            return cloud.auth.isSignedIn && cloud.auth.user?.id == user && cloud.auth.teamID == team
                && machines.session(session.machineID) === session && session.machine.shownStatus == .running
        }
        // task-owner: the source's liveness watch; cancelled when the source ends or is stopped
        let watch = Task { [weak server] in
            for await stillLive in live where !stillLive {
                server?.stop()
                return
            }
        }
        do {
            let port = try await server.start()
            guard server.isRunning else { throw Failure.asleep }
            running[tab] = (server, watch)
            logger.info("cloud desktop source for \(session.machineID, privacy: .public) on port \(port, privacy: .public)")
            return (port, server.secret)
        } catch {
            watch.cancel()
            // hostd hears the failure; no surface_gone for a source it never got.
            server.onEnd = nil
            server.stop()
            throw error
        }
    }

    func stop(tab: String) {
        guard let entry = running.removeValue(forKey: tab) else { return }
        entry.watch.cancel()
        entry.server.stop()
    }

    func stopAll() {
        let all = running.values
        running = [:]
        for entry in all {
            entry.watch.cancel()
            entry.server.stop()
        }
    }
}
