public import Foundation
public import Observation

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
    }

    /// The notices to show now, one per server and host, oldest first.
    public private(set) var notices: [ServerUpdateNotice] = []
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
    public init(policy: ServerSkewPolicy = ServerSkewPolicy(), restarter: any ServerRestarting,
                snoozes: ServerUpdateSnoozeStore, now: @escaping () -> Date = { Date() }) {
        self.policy = policy
        self.restarter = restarter
        self.snoozes = snoozes
        self.now = now
    }

    /// Records what a server said and updates its notice. The same skew again keeps the one notice.
    public func report(_ handshake: ServerHandshake, appCapabilities: Set<String>, bundledBuild: String?) {
        let key = Key(kind: handshake.kind, host: handshake.host)
        reported[key] = Reported(handshake: handshake, appCapabilities: appCapabilities, bundledBuild: bundledBuild)
        let notice = policy.notice(for: handshake, appCapabilities: appCapabilities, bundledBuild: bundledBuild)
        setNotice(notice, for: key)
    }

    /// Whether `capability` is on: the server on `host` advertises it. A server not seen yet, or
    /// one that advertises nothing, has none on.
    public func supports(_ capability: String, kind: ServerKind, host: ServerHost) -> Bool {
        reported[Key(kind: kind, host: host)]?.handshake.capabilities?.contains(capability) ?? false
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
            return .failed(String(describing: error))
        }
        let previous = reported[key]
        reported[key] = Reported(handshake: successor, appCapabilities: previous?.appCapabilities ?? [],
                                 bundledBuild: previous?.bundledBuild)
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
}
