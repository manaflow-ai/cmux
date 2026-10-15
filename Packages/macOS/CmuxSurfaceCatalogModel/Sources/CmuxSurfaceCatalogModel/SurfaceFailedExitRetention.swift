import Foundation

/// How long, and how many, failed tabless runs a machine lists.
///
/// The daemon keeps every exit receipt indefinitely and nothing on the Mac can
/// close a tabless exited terminal, so without a bound every failed run since
/// the machine was created would stay in its catalog. A failed run is news,
/// not history: it lists for ``window`` after it exited, and at most the
/// ``perMachineLimit`` most recent per machine. Rows that are not failed
/// tabless runs (``SurfaceResource/isFailedExitedTerminal``) pass through.
///
/// The provider applies this to every published snapshot; the Cloud tree reads
/// the same ``window`` for rows that age out between publishes.
public enum SurfaceFailedExitRetention {
    /// How long a failed tabless run stays listed after it exited.
    public static let window: TimeInterval = 6 * 60 * 60

    /// Most failed tabless runs listed per machine; the oldest go first.
    public static let perMachineLimit = 20

    /// When a failed run with no `exited_at` was first seen, by resource.
    public typealias FirstSeen = [SurfaceResourceID: Date]

    /// Records `now` for every failed tabless run in `resources` that carries no
    /// exit time and was not seen before, and forgets runs no longer present.
    /// - Parameters:
    ///   - firstSeen: The previous map.
    ///   - resources: The rows about to be published (the whole machine).
    ///   - now: The current time.
    /// - Returns: The map to keep for the next publish.
    public static func updatingFirstSeen(
        _ firstSeen: FirstSeen,
        resources: [SurfaceResource],
        now: Date
    ) -> FirstSeen {
        var next: FirstSeen = [:]
        for resource in resources where resource.isFailedExitedTerminal && resource.exit?.exitedAt == nil {
            next[resource.id] = firstSeen[resource.id] ?? now
        }
        return next
    }

    /// When a failed run counts as having ended: its exit time, else when this
    /// Mac first saw it, else now.
    static func endedAt(_ resource: SurfaceResource, firstSeen: FirstSeen, now: Date) -> Date {
        resource.exit?.exitedAt ?? firstSeen[resource.id] ?? now
    }

    /// Whether one failed run is still inside ``window``. True for any other row.
    public static func isWithinWindow(_ resource: SurfaceResource, firstSeen: FirstSeen = [:], now: Date) -> Bool {
        guard resource.isFailedExitedTerminal else { return true }
        return now.timeIntervalSince(endedAt(resource, firstSeen: firstSeen, now: now)) < window
    }

    /// `resources` without the failed tabless runs past ``window`` or beyond the
    /// ``perMachineLimit`` most recent on their machine. Order is preserved.
    public static func retained(
        _ resources: [SurfaceResource],
        firstSeen: FirstSeen,
        now: Date
    ) -> [SurfaceResource] {
        var recentByMachine: [SurfaceMachineID: [(id: SurfaceResourceID, endedAt: Date)]] = [:]
        for resource in resources where resource.isFailedExitedTerminal {
            guard isWithinWindow(resource, firstSeen: firstSeen, now: now) else { continue }
            recentByMachine[resource.machine, default: []].append(
                (resource.id, endedAt(resource, firstSeen: firstSeen, now: now))
            )
        }
        var kept: Set<SurfaceResourceID> = []
        for rows in recentByMachine.values {
            let newestFirst = rows.sorted {
                $0.endedAt != $1.endedAt ? $0.endedAt > $1.endedAt : $0.id.key < $1.id.key
            }
            kept.formUnion(newestFirst.prefix(perMachineLimit).map(\.id))
        }
        return resources.filter { !$0.isFailedExitedTerminal || kept.contains($0.id) }
    }
}
