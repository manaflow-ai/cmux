/// A settable ``PermissionProbe`` for tests and the gallery: grants live in
/// a map, and ``set(_:_:)`` sends one change to every listener.
///
/// ```swift
/// let probe = MockPermissionProbe()
/// probe.set(.fullDiskAccess, .granted) // listeners re-read and see it
/// ```
@MainActor
public final class MockPermissionProbe: PermissionProbe {
    private var statuses: [PermissionKind: PermissionStatus]
    private var listeners: [Int: AsyncStream<Void>.Continuation] = [:]
    private var nextListener = 0
    /// How many times a status was read (tests check no read storm).
    public private(set) var reads = 0

    public init(_ statuses: [PermissionKind: PermissionStatus] = [:]) {
        self.statuses = statuses
    }

    public func status(_ kind: PermissionKind, target: String?) async -> PermissionStatus {
        reads += 1
        if kind == .computerUse {
            let parts = kind.grants.map { statuses[$0] ?? .notDetermined }
            return parts.allSatisfy { $0 == .granted } ? .granted : (parts.contains(.denied) ? .denied : .notDetermined)
        }
        return statuses[kind] ?? .notDetermined
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = nextListener
        nextListener += 1
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            // task-owner: one bookkeeping hop back to the main actor when a listener ends.
            Task { @MainActor in self?.listeners[id] = nil }
        }
        return stream
    }

    /// Sets one grant and tells every listener.
    public func set(_ kind: PermissionKind, _ status: PermissionStatus) {
        statuses[kind] = status
        for listener in listeners.values { listener.yield() }
    }

    /// How many listeners follow the changes now.
    public var listenerCount: Int { listeners.count }
}
