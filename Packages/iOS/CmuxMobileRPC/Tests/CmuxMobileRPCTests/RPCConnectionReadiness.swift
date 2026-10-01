import CmuxMobileRPC

@MainActor
final class RPCConnectionReadiness: MobileConnectionReadinessProviding {
    var permitsConnection: Bool {
        didSet { events.continuation.yield(permitsConnection) }
    }
    private let events = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))

    init(permitsConnection: Bool) { self.permitsConnection = permitsConnection }

    func changes() -> AsyncStream<Bool> {
        events.continuation.yield(permitsConnection)
        return events.stream
    }
}
