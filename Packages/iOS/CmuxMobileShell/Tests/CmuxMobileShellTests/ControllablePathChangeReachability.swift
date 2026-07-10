import CmuxMobileShellModel
import CmuxMobileTransport

struct ControllablePathChangeReachability: ReachabilityProviding, Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    var isOnline: Bool { get async { true } }

    func pathChanges() -> AsyncStream<Void> { stream }

    func emitPathChange() { continuation.yield(()) }
}
