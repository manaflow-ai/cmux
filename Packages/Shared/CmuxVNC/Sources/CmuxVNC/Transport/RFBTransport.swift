/// A byte stream to an RFB server. `NetworkRFBTransport` is TCP on Apple
/// platforms; an app can supply another carrier (a tunnel, a test pipe).
public protocol RFBTransport: AnyObject, Sendable {
    /// Connects; returns when bytes can flow.
    func open() async throws
    /// The next bytes from the server, at least one. Throws
    /// `RFBError.connectionClosed` at the end of the stream.
    func receive() async throws -> [UInt8]
    /// Queues bytes in call order.
    func send(_ bytes: [UInt8]) async throws
    /// Closes the stream; pending reads throw.
    func close()
}
