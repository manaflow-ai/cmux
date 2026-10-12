import Foundation

/// Sends the pane's captured input on a `RemoteRdStreamTransport`.
@MainActor
public final class RemoteRdTransportInputSink: RemoteViewInputSink {
    private let transport: RemoteRdStreamTransport

    public init(transport: RemoteRdStreamTransport) {
        self.transport = transport
    }

    public func send(_ event: RemoteInputEvent) {
        transport.send(event)
    }
}
