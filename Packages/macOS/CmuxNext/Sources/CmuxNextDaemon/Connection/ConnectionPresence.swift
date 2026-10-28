import CmuxNextCompat

/// Whether a person can see what the app's daemon connections bring in, as the App reports it: the
/// Daemon target knows no windows. The composition root makes one, feeds it from its shown windows
/// and hands it to each machine's ``ConnectionHeartbeat``. With no presence a
/// heartbeat counts its app as shown. Chrome throttles the timers of a hidden or occluded page the
/// same way (`content/public/browser/visibility.h`).
public final class ConnectionPresence: Sendable {
    /// One change a heartbeat follows.
    public enum Edge: Sendable, Equatable {
        /// A window shows again after none did.
        case shown
        /// The last shown window hid.
        case hidden
    }

    public typealias Observer = @Sendable (Edge) -> Void

    private struct State {
        var shown: Bool
        var observers: [UInt64: Observer] = [:]
        var nextID: UInt64 = 0
    }

    // concurrency-allow: the shown flag and the observers, read synchronously by a heartbeat's arm and set by the App's one writer on the main actor (lock carve-out: a few fields, no I/O; observers run after the lock is released).
    private let state: Mutex<State>

    /// A presence that reports `shown` until ``update(shown:)`` changes it.
    public init(shown: Bool = true) {
        state = Mutex(State(shown: shown))
    }

    /// Whether a window shows now.
    public var isShown: Bool { state.withLock { $0.shown } }

    /// Records whether any window shows; a flip tells every observer ``Edge/shown`` or ``Edge/hidden``.
    public func update(shown: Bool) {
        let observers: [Observer]? = state.withLock { state in
            guard state.shown != shown else { return nil }
            state.shown = shown
            return state.observers.sorted { $0.key < $1.key }.map(\.value)
        }
        for observer in observers ?? [] { observer(shown ? .shown : .hidden) }
    }

    /// Calls `observer` on the writer's thread with each edge until the returned observation is
    /// cancelled or released.
    func observe(_ observer: @escaping Observer) -> ConnectionPresenceObservation {
        let id = state.withLock { state in
            state.nextID &+= 1
            state.observers.updateValue(observer, forKey: state.nextID)
            return state.nextID
        }
        return ConnectionPresenceObservation { [weak self] in self?.removeObserver(id) }
    }

    /// Observers registered now (tests).
    var observerCount: Int { state.withLock { $0.observers.count } }

    private func removeObserver(_ id: UInt64) {
        state.withLock { _ = $0.observers.removeValue(forKey: id) }
    }
}

/// One ``ConnectionPresence/observe(_:)`` registration: cancelled by ``cancel()`` or on release.
final class ConnectionPresenceObservation: Sendable {
    private let remove: @Sendable () -> Void

    init(remove: @escaping @Sendable () -> Void) {
        self.remove = remove
    }

    deinit { remove() }

    /// Stops the observer; later calls do nothing.
    func cancel() { remove() }
}
