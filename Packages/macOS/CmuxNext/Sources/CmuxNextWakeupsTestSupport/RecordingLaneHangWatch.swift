public import CmuxNextTrace
import CmuxNextCompat

/// A ``HangWatchScoping`` that records each lane a type registers, each scope it opens (lane and deadline),
/// the scopes open right now and each lane it frees: what a lane test reads to prove one scope per unit of
/// work, none around a wait, and an unregister when the lane ends. Registrations come from a real
/// ``HangWatch`` of its own, so they are valid tokens; nothing is ever reported.
///
/// ```swift
/// let hangs = RecordingLaneHangWatch()
/// let lane = MyLane(hangs: hangs)
/// #expect(hangs.lanes == ["my.lane"])
/// #expect(hangs.entered("my.lane") == 1)
/// ```
public final class RecordingLaneHangWatch: HangWatchScoping {
    /// One scope: the lane it opened on and its deadline.
    public struct Scope: Equatable, Sendable {
        public var lane: String
        public var deadline: Duration

        public init(lane: String, deadline: Duration) {
            self.lane = lane
            self.deadline = deadline
        }
    }

    private struct State {
        var names: [HangWatch.Registration: String] = [:]
        var lanes: [String] = []
        var unregistered: [String] = []
        var open: [Scope] = []
        var entered: [Scope] = []
    }

    private let tokens = HangWatch()
    private let state = Mutex(State())
    /// Each lane as it is freed, for a lane that frees itself later on another thread.
    public let unregistrations: AsyncStream<String>
    private let freed: AsyncStream<String>.Continuation

    public init() {
        (unregistrations, freed) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(64))
    }

    /// Every lane registered, in order (a lane registered twice is listed twice).
    public var lanes: [String] { state.withLock { $0.lanes } }
    /// Every lane freed, in order.
    public var unregistered: [String] { state.withLock { $0.unregistered } }
    /// Every scope opened so far, in order.
    public var entered: [Scope] { state.withLock { $0.entered } }

    /// How many scopes lane `lane` opened so far.
    public func entered(_ lane: String) -> Int {
        state.withLock { state in state.entered.filter { scope in scope.lane == lane }.count }
    }

    /// The scopes of lane `lane` open now, outermost first.
    public func open(_ lane: String) -> [Scope] {
        state.withLock { state in state.open.filter { scope in scope.lane == lane } }
    }

    public func registerLane(_ name: StaticString) -> HangWatch.Registration {
        let registration = tokens.registerLane(name)
        state.withLock { state in
            state.names[registration] = name.description
            state.lanes.append(name.description)
        }
        return registration
    }

    public func unregister(_ registration: HangWatch.Registration) {
        let name = state.withLock { state -> String? in
            guard let name = state.names.removeValue(forKey: registration) else { return nil }
            state.unregistered.append(name)
            return name
        }
        tokens.unregister(registration)
        if let name { freed.yield(name) }
    }

    public func watch<T>(_ registration: HangWatch.Registration, deadline: Duration, _ body: () throws -> T) rethrows -> T {
        let scope = state.withLock { state -> Scope in
            let scope = Scope(lane: state.names[registration] ?? "unregistered", deadline: deadline)
            state.open.append(scope)
            state.entered.append(scope)
            return scope
        }
        defer {
            state.withLock { state in
                if let index = state.open.lastIndex(of: scope) { state.open.remove(at: index) }
            }
        }
        return try body()
    }
}
