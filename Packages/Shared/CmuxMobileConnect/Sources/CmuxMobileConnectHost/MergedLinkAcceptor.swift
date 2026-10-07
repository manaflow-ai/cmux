public import CmuxLink

/// One `LinkAcceptor` over several carriers' acceptors, so one `LinkHost`
/// (and one `MobileHost`) serves direct, WebRTC and WireGuard sessions alike.
public struct MergedLinkAcceptor: LinkAcceptor {
    public let incoming: AsyncStream<any LinkTransport>

    public init(_ acceptors: [any LinkAcceptor]) {
        let (stream, continuation) = AsyncStream.makeStream(of: (any LinkTransport).self, bufferingPolicy: .unbounded)
        incoming = stream
        let sources = acceptors.map(\.incoming)
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    group.addTask {
                        for await transport in source { continuation.yield(transport) }
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
