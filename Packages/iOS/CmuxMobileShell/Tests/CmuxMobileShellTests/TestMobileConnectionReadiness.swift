import CmuxMobileRPC

@MainActor
final class TestMobileConnectionReadiness: MobileConnectionReadinessProviding {
    var permitsConnection: Bool
    private let stream = AsyncStream<Bool>.makeStream()

    init(permitsConnection: Bool) { self.permitsConnection = permitsConnection }
    func changes() -> AsyncStream<Bool> { stream.stream }
    func publish(_ ready: Bool) {
        permitsConnection = ready
        stream.continuation.yield(ready)
    }
}
