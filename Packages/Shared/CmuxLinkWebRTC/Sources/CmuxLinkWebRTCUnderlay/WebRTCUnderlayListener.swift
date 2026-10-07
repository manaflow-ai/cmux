public import CmuxLinkWG
public import CmuxLinkWebRTC

/// B3's `DatagramUnderlayListener` over `WebRTCDatagramListener`. Call
/// `listener.start()` before passing it to the V2 acceptor.
public final class WebRTCUnderlayListener: DatagramUnderlayListener {
    public let listener: WebRTCDatagramListener
    public let incoming: AsyncStream<any DatagramUnderlay>
    private let pump: Task<Void, Never>

    public init(listener: WebRTCDatagramListener) {
        self.listener = listener
        let (incoming, sink) = AsyncStream.makeStream(of: (any DatagramUnderlay).self, bufferingPolicy: .unbounded)
        self.incoming = incoming
        let source = listener.incoming
        pump = Task {
            for await channel in source { sink.yield(WebRTCUnderlay(channel: channel)) }
            sink.finish()
        }
    }

    deinit { pump.cancel() }
}
