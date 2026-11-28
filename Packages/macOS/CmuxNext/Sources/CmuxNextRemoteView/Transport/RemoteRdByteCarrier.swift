public import Foundation

/// One event of a `RemoteRdByteCarrier`, delivered on the transport's queue.
public nonisolated enum RemoteRdCarrierEvent: Sendable {
    /// The byte path is open: the transport sends hello and start.
    case ready
    /// Bytes from the host, in order.
    case data(Data)
    /// The byte path ended or failed (it may come more than once).
    case closed
}

/// The ordered byte path under `RemoteRdStreamTransport` (cx-2cob slice 2):
/// a TCP connection to a host on this Mac's loopback
/// (`RemoteRdLoopbackCarrier`), or a `loopback-forward-v1` stream to a host
/// on another machine's loopback, over that machine's daemon link (the app's
/// carrier). The transport above it is the same for both.
public nonisolated protocol RemoteRdByteCarrier: AnyObject, Sendable {
    /// Opens the path. Called once; every event runs on `queue`, in order.
    func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void)
    /// Queues `bytes` after the bytes sent before; a failure is `.closed`.
    func send(_ bytes: Data)
    /// Ends the path; sends after it are dropped.
    func cancel()
}
