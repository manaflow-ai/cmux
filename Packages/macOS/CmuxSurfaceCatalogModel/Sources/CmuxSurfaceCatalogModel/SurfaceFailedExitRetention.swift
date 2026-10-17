import Foundation

/// How long, and how many, failed tabless runs a machine lists.
///
/// (An extension on ``SurfaceResource``, the rows it bounds, rather than a
/// static namespace.)
///
/// The daemon keeps every exit receipt indefinitely and nothing on the Mac can
/// close a tabless exited terminal, so without a bound every failed run since
/// the machine was created would stay in its catalog. A failed run is news,
/// not history: it lists for ``failedExitRetentionWindow`` after it exited, and at most the
/// ``failedExitPerMachineLimit`` most recent per machine. Rows that are not failed
/// tabless runs (``SurfaceResource/isFailedExitedTerminal``) pass through.
///
/// The provider applies this to every published snapshot; the Cloud tree reads
/// the same ``failedExitRetentionWindow`` for rows that age out between publishes.
public extension SurfaceResource {
    /// How long a failed tabless run stays listed after it exited.
    static let failedExitRetentionWindow: TimeInterval = 6 * 60 * 60

    /// Most failed tabless runs listed per machine; the oldest go first.
    static let failedExitPerMachineLimit = 20

    /// When a failed run with no `exited_at` was first seen, by resource.
    typealias FailedExitFirstSeen = [SurfaceResourceID: Date]

    /// Records `now` for every failed tabless run in `resources` that carries no
    /// exit time and was not seen before, and forgets runs no longer present.
    /// - Parameters:
    ///   - firstSeen: The previous map.
    ///   - resources: The rows about to be published (the whole machine).
    ///   - now: The current time.
    /// - Returns: The map to keep for the next publish.
    static func updatingFailedExitFirstSeen(
        _ firstSeen: FailedExitFirstSeen,
        resources: [SurfaceResource],
        now: Date
    ) -> FailedExitFirstSeen {
        var next: FailedExitFirstSeen = [:]
        for resource in resources where resource.isFailedExitedTerminal && resource.exit?.exitedAt == nil {
            next[resource.id] = firstSeen[resource.id] ?? now
        }
        return next
    }

    /// When a failed run counts as having ended: its exit time, else when this
    /// Mac first saw it, else now.
    internal static func failedExitEndedAt(_ resource: SurfaceResource, firstSeen: FailedExitFirstSeen, now: Date) -> Date {
        resource.exit?.exitedAt ?? firstSeen[resource.id] ?? now
    }

    /// Whether one failed run is still inside ``failedExitRetentionWindow``. True for any other row.
    static func isWithinFailedExitWindow(_ resource: SurfaceResource, firstSeen: FailedExitFirstSeen = [:], now: Date) -> Bool {
        guard resource.isFailedExitedTerminal else { return true }
        return now.timeIntervalSince(failedExitEndedAt(resource, firstSeen: firstSeen, now: now)) < failedExitRetentionWindow
    }

    /// `resources` without the failed tabless runs past ``failedExitRetentionWindow`` or beyond the
    /// ``failedExitPerMachineLimit`` most recent on their machine. Order is preserved.
    static func retainingFailedExits(
        _ resources: [SurfaceResource],
        firstSeen: FailedExitFirstSeen,
        now: Date
    ) -> [SurfaceResource] {
        var recentByMachine: [SurfaceMachineID: [(id: SurfaceResourceID, endedAt: Date)]] = [:]
        for resource in resources where resource.isFailedExitedTerminal {
            guard isWithinFailedExitWindow(resource, firstSeen: firstSeen, now: now) else { continue }
            recentByMachine[resource.machine, default: []].append(
                (resource.id, failedExitEndedAt(resource, firstSeen: firstSeen, now: now))
            )
        }
        var kept: Set<SurfaceResourceID> = []
        for rows in recentByMachine.values {
            let newestFirst = rows.sorted {
                $0.endedAt != $1.endedAt ? $0.endedAt > $1.endedAt : $0.id.key < $1.id.key
            }
            kept.formUnion(newestFirst.prefix(failedExitPerMachineLimit).map(\.id))
        }
        return resources.filter { !$0.isFailedExitedTerminal || kept.contains($0.id) }
    }
}
