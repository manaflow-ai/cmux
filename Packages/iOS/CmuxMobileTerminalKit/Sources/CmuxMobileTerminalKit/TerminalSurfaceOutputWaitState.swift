/// Pure reducer for output-application waiters keyed by surface generation.
public struct TerminalSurfaceOutputWaitState: Equatable, Sendable {
    /// Stable identifier for one pending output-completion continuation.
    public typealias WaitID = UInt64

    /// Registered wait ids grouped by terminal surface generation.
    public private(set) var waitsByGeneration: [UInt64: Set<WaitID>] = [:]
    private var nextWaitID: WaitID = 0

    /// Creates an empty output-wait reducer.
    public init() {}

    /// Registers a waiter for output applied to `generation`.
    /// - Parameter generation: The surface generation that must apply output.
    /// - Returns: The waiter id to complete or cancel later.
    public mutating func register(generation: UInt64) -> WaitID {
        nextWaitID &+= 1
        waitsByGeneration[generation, default: []].insert(nextWaitID)
        return nextWaitID
    }

    /// Completes a specific waiter.
    /// - Parameters:
    ///   - generation: The generation the waiter was registered against.
    ///   - id: The waiter id returned by ``register(generation:)``.
    /// - Returns: `true` when the waiter was still pending.
    public mutating func complete(generation: UInt64, id: WaitID) -> Bool {
        guard waitsByGeneration[generation]?.remove(id) != nil else {
            return false
        }
        if waitsByGeneration[generation]?.isEmpty == true {
            waitsByGeneration[generation] = nil
        }
        return true
    }

    /// Cancels every waiter for one generation.
    /// - Parameter generation: The surface generation to cancel.
    /// - Returns: The canceled waiter ids in deterministic order.
    public mutating func cancel(generation: UInt64) -> [WaitID] {
        Array(waitsByGeneration.removeValue(forKey: generation) ?? []).sorted()
    }

    /// Cancels every pending waiter across all generations.
    /// - Returns: The canceled generation/id pairs in deterministic order.
    public mutating func cancelAll() -> [(generation: UInt64, id: WaitID)] {
        let cancelled = waitsByGeneration.flatMap { generation, ids in
            ids.map { (generation: generation, id: $0) }
        }.sorted {
            if $0.generation == $1.generation {
                return $0.id < $1.id
            }
            return $0.generation < $1.generation
        }
        waitsByGeneration.removeAll()
        return cancelled
    }
}
