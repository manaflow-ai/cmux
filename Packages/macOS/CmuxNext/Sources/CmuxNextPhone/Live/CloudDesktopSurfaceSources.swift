public import CmuxNextCompat
public import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "phone.surface")

/// The phone's view-only Cloud desktops (the Chief info page's Computer card, cmux issue 31488):
/// one ``CloudDesktopSurfaceServer`` per hostd surface tab `c~<machine_id>~<team_id>`. The app's
/// `grant` decides each start: it refuses a machine that is not a current, owned, running machine
/// of the signed-in account (hostd checks the same before it asks), and hands back the frame feed
/// and a liveness check. A source stops when that check turns false (the account changed, the
/// machine left the list or stopped running), its desktop stream ends, or hostd stops it.
@MainActor
public final class CloudDesktopSurfaceSources {
    public struct Target: Equatable, Sendable {
        public let machine: String
        public let team: String

        public init(machine: String, team: String) {
            self.machine = machine
            self.team = team
        }
    }

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case notCloudDesktop, forbidden, asleep, unreachable

        public var description: String {
            switch self {
            case .notCloudDesktop: "that tab is not a Cloud desktop"
            case .forbidden: "that Cloud machine is not this account's own"
            case .asleep: "that Cloud machine is not running"
            case .unreachable: "this Mac cannot reach that Cloud machine's desktop"
            }
        }
    }

    /// What the app grants one start: the machine's frames, its name in logs (the machine id,
    /// never a secret), and whether it may still stream (read under observation, so the source
    /// stops the moment it turns false).
    public struct Grant {
        public var feed: SurfaceFrameFeed
        public var label: String
        public var stillLive: @MainActor () -> Bool

        public init(feed: SurfaceFrameFeed, label: String, stillLive: @escaping @MainActor () -> Bool) {
            self.feed = feed
            self.label = label
            self.stillLive = stillLive
        }
    }

    /// The `c~<machine_id>~<team_id>` tab of a Cloud desktop; nil for anything else (`~` is never in a Cloud id).
    public nonisolated static func target(of tab: String) -> Target? {
        let parts = tab.split(separator: "~", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "c", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return Target(machine: String(parts[1]), team: String(parts[2]))
    }

    private let grant: @MainActor (Target) async throws -> Grant
    private var running: [String: (server: CloudDesktopSurfaceServer, watch: Task<Void, Never>)] = [:]

    public init(grant: @escaping @MainActor (Target) async throws -> Grant) {
        self.grant = grant
    }

    public func start(tab: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
        guard let target = Self.target(of: tab) else { throw Failure.notCloudDesktop }
        let granted = try await grant(target)
        guard granted.stillLive() else { throw Failure.asleep }
        stop(tab: tab)
        let server = CloudDesktopSurfaceServer(feed: granted.feed, label: granted.label)
        server.onEnd = { [weak self, weak server] in
            if let server, let entry = self?.running[tab], entry.server === server {
                entry.watch.cancel()
                self?.running[tab] = nil
            }
            onExit()
        }
        let stillLive = granted.stillLive
        let live = ObservationStream { stillLive() }
        // task-owner: the source's liveness watch; cancelled when the source ends or is stopped
        let watch = Task { [weak server] in
            for await isLive in live where !isLive {
                server?.stop()
                return
            }
        }
        do {
            let port = try await server.start()
            guard server.isRunning else { throw Failure.asleep }
            running[tab] = (server, watch)
            logger.info("cloud desktop source for \(granted.label, privacy: .public) on port \(port, privacy: .public)")
            return (port, server.secret)
        } catch {
            watch.cancel()
            // hostd hears the failure; no surface_gone for a source it never got.
            server.onEnd = nil
            server.stop()
            throw error
        }
    }

    public func stop(tab: String) {
        guard let entry = running.removeValue(forKey: tab) else { return }
        entry.watch.cancel()
        entry.server.stop()
    }

    public func stopAll() {
        let all = running.values
        running = [:]
        for entry in all {
            entry.watch.cancel()
            entry.server.stop()
        }
    }
}
