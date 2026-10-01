import CmuxMobileRPC

@MainActor
final class TestMobileConnectionReadiness: MobileConnectionReadinessProviding {
    var permitsConnection: Bool
    private let stream = AsyncStream<Bool>.makeStream()
    private let terminations = AsyncStream<Void>.makeStream()

    init(permitsConnection: Bool) {
        self.permitsConnection = permitsConnection
        let termination = terminations.continuation
        stream.continuation.onTermination = { _ in
            termination.yield(())
            termination.finish()
        }
    }
    func changes() -> AsyncStream<Bool> { stream.stream }
    func waitUntilTerminated() async { for await _ in terminations.stream { return } }
    func publish(_ ready: Bool) {
        permitsConnection = ready
        stream.continuation.yield(ready)
    }
}
