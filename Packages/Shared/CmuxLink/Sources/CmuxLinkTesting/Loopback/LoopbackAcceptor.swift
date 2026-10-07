import CmuxLink

/// The host end of a `LoopbackNetwork`.
public final class LoopbackAcceptor: LinkAcceptor {
    public let incoming: AsyncStream<any LinkTransport>
    let continuation: AsyncStream<any LinkTransport>.Continuation

    init() {
        (incoming, continuation) = AsyncStream<any LinkTransport>.makeStream()
    }
}
