import CmuxNextWakeups
import Foundation

/// Keeps a page relay connection open while something uses it (a page's event listener, or a call
/// in flight) and closes it `idle` after the last use ends (audit 2026-11-18 §14: relays were never
/// closed, so every page ever shown kept a daemon subscription and a reconnect loop). A use that
/// begins before the deadline cancels it, so a page shown again soon reuses its connection.
@MainActor
public final class PageRelayUse {
    private var uses = 0
    private let idle: Duration
    private let timer: DemandTimer
    private let close: @MainActor () async -> Void

    public init(idle: Duration = .seconds(30), clock: any Clock<Duration> = ContinuousClock(),
                close: @escaping @MainActor () async -> Void) {
        self.idle = idle
        self.timer = DemandTimer(owner: "page-relay-idle-close", clock: clock)
        self.close = close
    }

    /// Uses now (listeners plus calls in flight).
    public var count: Int { uses }

    public func begin() {
        uses += 1
        timer.cancel()
    }

    public func end() {
        uses = max(0, uses - 1)
        guard uses == 0 else { return }
        timer.schedule(after: idle) { @MainActor [weak self] in await self?.closeIfIdle() }
    }

    private func closeIfIdle() async {
        guard uses == 0 else { return }
        await close()
    }
}

/// The page a relay connection serves (`page-router-v1`).
public struct PageRelayPage {
    public init() {}
    /// The daemon page id of a descriptor id (`cmux.history` -> `history`), or nil when it is not
    /// one (1-64 of `a-z 0-9 -`, a letter first): such a relay serves no page and may call nothing.
    public static func id(_ descriptor: String) -> String? {
        let id = descriptor.hasPrefix("cmux.") ? String(descriptor.dropFirst("cmux.".count)) : descriptor
        guard (1...64).contains(id.count), let first = id.unicodeScalars.first, ("a"..."z").contains(first),
              id.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else {
            return nil
        }
        return id
    }
}
