import Foundation

/// Serializes the callbacks NetworkExtension can deliver to one provider
/// process while a start is still settling. macOS may replay a start request
/// after the adapter has already reached the running state; forwarding that
/// replay to WireGuardAdapter turns a successful start into an invalid-state
/// error and makes NetworkExtension tear the tunnel down.
actor CloudTunnelProviderStartGate {
    typealias Completion = @Sendable (CloudTunnelProviderError?) -> Void

    enum Request: Equatable, Sendable {
        case begin(generation: UInt64)
        case coalesced(generation: UInt64, waiterCount: Int)
        case alreadyStarted(generation: UInt64)
    }

    struct Finish: Sendable {
        let generation: UInt64
        let succeeded: Bool
        let completions: [Completion]

        var callbackCount: Int { completions.count }
    }

    private enum State {
        case idle
        case starting(generation: UInt64)
        case started(generation: UInt64)
    }

    private var state = State.idle
    private var nextGeneration: UInt64 = 0
    private var pendingCompletions: [Completion] = []

    /// Registers one NetworkExtension start callback and reports whether the
    /// provider should start WireGuard, wait for an existing start, or answer
    /// immediately because the adapter is already running.
    func request(completion: @escaping Completion) -> Request {
        switch state {
        case .idle:
            nextGeneration += 1
            let generation = nextGeneration
            state = .starting(generation: generation)
            pendingCompletions = [completion]
            return .begin(generation: generation)
        case .starting(let generation):
            pendingCompletions.append(completion)
            return .coalesced(generation: generation, waiterCount: pendingCompletions.count)
        case .started(let generation):
            return .alreadyStarted(generation: generation)
        }
    }

    /// Completes the current start exactly once. Every callback registered for
    /// the same start receives the same result, and later duplicate starts are
    /// answered as already running until the provider is stopped and replaced.
    func finish(error: CloudTunnelProviderError?) -> Finish? {
        guard case .starting(let generation) = state else { return nil }
        state = error == nil ? .started(generation: generation) : .idle
        let completions = pendingCompletions
        pendingCompletions.removeAll(keepingCapacity: false)
        return Finish(generation: generation, succeeded: error == nil, completions: completions)
    }
}

/// Failures the provider reports through NetworkExtension.
enum CloudTunnelProviderError: Error, Sendable {
    case missingConfiguration
    case unsupportedSchema
    case invalidConfiguration
    case couldNotDetermineFileDescriptor
    case dnsResolutionFailure
    case couldNotSetNetworkSettings
    case couldNotStartBackend
    case invalidState
}
