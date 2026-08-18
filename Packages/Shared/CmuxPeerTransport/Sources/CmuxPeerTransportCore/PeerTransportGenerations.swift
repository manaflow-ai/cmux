import Foundation

/// The three distinct monotonic generations the transport fences on.
///
/// - `identity`: changes only when the endpoint key or account binding
///   changes. It is included in broker registration and pair grants; rotating
///   it orphans the registration, so runtime churn must never bump it.
/// - `runtime`: changes whenever the process's endpoint instance is recreated
///   (health-watchdog recreate, backgrounding teardown). Local only; stale
///   async results are rejected against it.
/// - `connection`: changes per dial attempt on a peer supervisor. A
///   continuation that resumes after an await must revalidate its captured
///   connection generation before mutating state.
public struct PeerTransportGeneration: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func next() -> Self {
        Self(rawValue: rawValue &+ 1)
    }

    public var description: String {
        "g\(rawValue)"
    }

    public static let initial = Self(rawValue: 0)
}

/// Thread-safe generation counter. `advance()` returns the new value.
public final class PeerGenerationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PeerTransportGeneration

    public init(initial: PeerTransportGeneration = .initial) {
        self.current = initial
    }

    public var value: PeerTransportGeneration {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    @discardableResult
    public func advance() -> PeerTransportGeneration {
        lock.lock()
        defer { lock.unlock() }
        current = current.next()
        return current
    }

    /// True when `captured` is still the current generation. Callers use this
    /// after every await to reject stale continuations.
    public func isCurrent(_ captured: PeerTransportGeneration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current == captured
    }
}
