import Foundation
import os
import Synchronization

/// Assigns `value` only when it differs. Observation (`@Observable`)
/// notifies on every set, even of the same value, so a view that writes back
/// what it just read would wake every observer again: an observation
/// feedback loop (plans/cmux-next/idle-wakeups.md). Returns true on change.
@discardableResult
public func assignIfChanged<Root: AnyObject, Value: Equatable>(
    _ root: Root, _ keyPath: ReferenceWritableKeyPath<Root, Value>, _ value: Value
) -> Bool {
    guard root[keyPath: keyPath] != value else { return false }
    root[keyPath: keyPath] = value
    return true
}

/// Detects update cycles: an update that re-enters itself (A changes B, B's
/// observer changes A while A is still applying). Debug builds log each
/// re-entry and count it in the ledger under `owner` with reason
/// "reentrant update"; release builds only count.
public final class UpdateCycleDetector: Sendable {
    public let owner: String
    /// Nesting beyond this depth is reported.
    public let maxDepth: Int
    private let depth = Mutex<Int>(0)
    private let reentries = Atomic<UInt64>(0)
    private let ledger: WakeupLedger
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "wakeups")

    public init(owner: String, maxDepth: Int = 1, ledger: WakeupLedger = .shared) {
        self.owner = owner
        self.maxDepth = maxDepth
        self.ledger = ledger
    }

    /// Re-entries seen since launch.
    public var reentryCount: UInt64 { reentries.load(ordering: .relaxed) }

    /// Runs `update`, reporting when it runs inside another update of this owner.
    public func run<T>(_ update: () throws -> T) rethrows -> T {
        let level = depth.withLock { depth -> Int in
            depth += 1
            return depth
        }
        defer { depth.withLock { $0 -= 1 } }
        if level > maxDepth {
            reentries.add(1, ordering: .relaxed)
            ledger.record(owner, reason: "reentrant update")
            #if DEBUG
            Self.logger.error("re-entrant update of \(self.owner, privacy: .public) at depth \(level)")
            #endif
        }
        return try update()
    }
}
