public import Foundation
public import Observation
import os

/// Holds each server's last handshake and the notices to show, and runs a confirmed restart.
/// Reporting skew never restarts anything: only ``restart(_:)``, which the app calls after the
/// person confirmed, does.
///
/// ```swift
/// let servers = ServerUpdateCoordinator(restarter: appRestarter, snoozes: ServerUpdateSnoozeStore(defaults: .standard))
/// servers.report(handshake, appCapabilities: optional, bundledBuild: bundled)
/// ```
@MainActor
@Observable
public final class ServerUpdateCoordinator {
    private struct Key: Hashable {
        let kind: ServerKind
        let host: ServerHost
    }

    private struct Reported {
        var handshake: ServerHandshake
        var appCapabilities: Set<String>
        var bundledBuild: String?
        var handingOff: Bool
    }

    /// The notices to show now, one per server and host, oldest first.
    public private(set) var notices: [ServerUpdateNotice] = []
    /// Counts handshakes taken in, so a view of ``settingsReport(socketPath:tailnetAddress:)`` updates
    /// when a server's build changes without its notice changing.
    public private(set) var handshakeRevision = 0
    /// True from a handshake until the connection has held for ``offerHold``: a new update offer waits.
    /// The handshake right after launch or a daemon handoff reported skew while the daemon settled,
    /// and "Update ready" showed on every launch.
    public private(set) var holdsOffers = true
    /// How long a new handshake's connection holds before an update offer shows.
    public static let offerHold: Duration = .seconds(10)
    @ObservationIgnored private var offerHoldTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var reported: [Key: Reported] = [:]
    /// Notices already restarted once this launch: a restart that gained nothing is not offered again.
    @ObservationIgnored private var restartedOnce: Set<String> = []
    private let policy: ServerSkewPolicy
    private let restarter: any ServerRestarting
    private let snoozes: ServerUpdateSnoozeStore
    private let now: () -> Date

    /// How long the close button snoozes a notice.
    public static let snoozeInterval: TimeInterval = 24 * 3600

    /// - Parameters:
    ///   - policy: Decides what counts as skew (default: the shipped catalog).
    ///   - restarter: Restarts a server after the person confirmed.
    ///   - snoozes: Where closed notices persist.
    ///   - now: The clock (tests pass a fixed date).
    ///   - clock: The clock of the offer hold (tests pass a manual clock).
    public init<C: Clock & Sendable>(policy: ServerSkewPolicy = ServerSkewPolicy(), restarter: any ServerRestarting,
                                     snoozes: ServerUpdateSnoozeStore, now: @escaping () -> Date = { Date() },
                                     clock: C = ContinuousClock()) where C.Duration == Duration {
        self.policy = policy
        self.restarter = restarter
        self.snoozes = snoozes
        self.now = now
        // wakeup-allow: the offer hold's one-shot deadline (holdOffers); the next handshake cancels it.
        sleep = { try await clock.sleep(for: $0) }
    }

    /// Records what a server said and updates its notice. The same skew again keeps the one notice.
    /// - Parameter handingOff: The app is already replacing this server with its bundled build (the
    ///   launch handoff after an update): no notice, since a Restart would only race that handoff.
    public func report(_ handshake: ServerHandshake, appCapabilities: Set<String>, bundledBuild: String?,
                       handingOff: Bool = false) {
        let key = Key(kind: handshake.kind, host: handshake.host)
        reported[key] = Reported(handshake: handshake, appCapabilities: appCapabilities, bundledBuild: bundledBuild,
                                 handingOff: handingOff)
        handshakeRevision += 1
        holdOffers()
        let notice = handingOff ? nil
            : policy.notice(for: handshake, appCapabilities: appCapabilities, bundledBuild: bundledBuild)
        setNotice(notice, for: key)
    }

    /// Holds new offers for ``offerHold`` from now (one task; the next handshake starts it again).
    private func holdOffers() {
        holdsOffers = true
        offerHoldTask?.cancel()
        let sleep = sleep
        offerHoldTask = Task { [weak self] in
            // wakeup-allow: one-shot deadline of a handshake's offer hold; the next handshake cancels it.
            do { try await sleep(Self.offerHold) } catch { return }
            guard !Task.isCancelled else { return }
            self?.holdsOffers = false
        }
    }

    /// Whether `capability` is on: the server on `host` advertises it. A server not seen yet, or
    /// one that advertises nothing, has none on.
    public func supports(_ capability: String, kind: ServerKind, host: ServerHost) -> Bool {
        reported[Key(kind: kind, host: host)]?.handshake.capabilities?.contains(capability) ?? false
    }

    /// Settings > Server: a row per server heard from. Unlike ``notices`` it ignores snoozes, since
    /// the person opened Settings to look; a server restarted once that still lacks capabilities is
    /// not offered again, as for the toast.
    /// - Parameters:
    ///   - socketPath: This Mac's cmux-tui control socket, if known.
    ///   - tailnetAddress: This Mac's Tailscale address, if known.
    public func settingsReport(socketPath: String?, tailnetAddress: String?) -> ServerSettingsReport {
        _ = handshakeRevision
        let ordered = reported.keys.sorted { ($0.kind.rawValue, $0.host.key) < ($1.kind.rawValue, $1.host.key) }
        let rows = ordered.compactMap { key -> ServerSettingsRow? in
            guard let entry = reported[key] else { return nil }
            var notice = entry.handingOff ? nil : policy.notice(for: entry.handshake, appCapabilities: entry.appCapabilities,
                                       bundledBuild: entry.bundledBuild)
            if let current = notice, restartedOnce.contains(current.id) { notice = nil }
            return ServerSettingsReport.row(handshake: entry.handshake, notice: notice, socketPath: socketPath,
                                            tailnetAddress: tailnetAddress)
        }
        return ServerSettingsReport(rows: rows)
    }

    /// The last handshake of `kind` on `host`.
    public func handshake(_ kind: ServerKind, host: ServerHost) -> ServerHandshake? {
        reported[Key(kind: kind, host: host)]?.handshake
    }

    /// The close button: hides `notice` for ``snoozeInterval`` (that server build only).
    public func snooze(_ notice: ServerUpdateNotice) {
        let date = now()
        snoozes.snooze(notice.id, until: date.addingTimeInterval(Self.snoozeInterval), now: date)
        notices.removeAll { $0.id == notice.id }
    }

    /// Restarts `notice`'s server (the person confirmed), then reads its successor's handshake:
    /// the new capabilities turn on and the notice ends.
    public func restart(_ notice: ServerUpdateNotice) async -> ServerRestartOutcome {
        let key = Key(kind: notice.kind, host: notice.host)
        restartedOnce.insert(notice.id)
        let successor: ServerHandshake
        do {
            successor = try await restarter.restart(notice.kind, host: notice.host)
        } catch {
            // The reason is for the log; the toast says it plainly (ServerRestartOutcome.message).
            Self.logger.error("restart of \(notice.serverLabel, privacy: .public) failed: \(String(describing: error))")
            return .failed(String(describing: error))
        }
        let previous = reported[key]
        reported[key] = Reported(handshake: successor, appCapabilities: previous?.appCapabilities ?? [],
                                 bundledBuild: previous?.bundledBuild, handingOff: false)
        handshakeRevision += 1
        let still = policy.notice(for: successor, appCapabilities: previous?.appCapabilities ?? [],
                                  bundledBuild: previous?.bundledBuild)
        notices.removeAll { $0.kind == notice.kind && $0.host == notice.host }
        guard let still else { return .restarted(gained: notice.gainedFeatures) }
        // Not offered again this launch: the same restart would gain nothing again.
        restartedOnce.insert(still.id)
        return .stillMissing(still.missingCapabilities.isEmpty ? notice.missingCapabilities : still.missingCapabilities)
    }

    private func setNotice(_ notice: ServerUpdateNotice?, for key: Key) {
        let index = notices.firstIndex { $0.kind == key.kind && $0.host == key.host }
        guard let notice, !restartedOnce.contains(notice.id), !snoozes.isSnoozed(notice.id, at: now()) else {
            if let index { notices.remove(at: index) }
            return
        }
        if let index {
            if notices[index] != notice { notices[index] = notice }
        } else {
            notices.append(notice)
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "server-updates")
}
