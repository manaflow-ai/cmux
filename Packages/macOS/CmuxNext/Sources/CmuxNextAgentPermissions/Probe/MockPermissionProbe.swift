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
        listeners[nextListener] = continuation
        nextListener += 1
        return stream
    }

    /// Sets one grant and tells every listener; a listener whose stream ended is dropped here, on the main actor,
    /// with no hop from its termination.
    public func set(_ kind: PermissionKind, _ status: PermissionStatus) {
        statuses[kind] = status
        for (id, listener) in listeners {
            if case .terminated = listener.yield() { listeners[id] = nil }
        }
    }

    /// How many listeners follow the changes now (an ended one counts until the next ``set(_:_:)``).
    public var listenerCount: Int { listeners.count }
}
