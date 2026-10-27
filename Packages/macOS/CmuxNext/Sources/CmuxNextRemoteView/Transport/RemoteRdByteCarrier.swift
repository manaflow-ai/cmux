public import Foundation

/// One event of a `RemoteRdByteCarrier`, delivered on the transport's queue.
public nonisolated enum RemoteRdCarrierEvent: Sendable {
    /// The byte path is open: the transport sends hello and start.
    case ready
    /// Bytes from the host, in order.
    case data(Data)
    /// The bytes queued for the host fell back to half the carrier's bound after it was backed up
    /// (``RemoteRdByteCarrier/isBackedUp``): the transport sends what it held back.
    case writable
    /// The byte path ended or failed (it may come more than once).
    case closed
}

/// The ordered byte path under `RemoteRdStreamTransport` (cx-2cob slice 2):
/// a TCP connection to a host on this Mac's loopback
/// (`RemoteRdLoopbackCarrier`), or a `loopback-forward-v1` stream to a host
/// on another machine's loopback, over that machine's daemon link (the app's
/// carrier). The transport above it is the same for both.
///
/// Backpressure: a carrier queues what ``send(_:)`` hands it until the path takes it. Once it holds its
/// bound unsent it is backed up, and the transport stops producing bulk frames (feedback, input packets,
/// upstream media) until `.writable`, so the queue never grows past the bound and one batch, and no byte is
/// dropped. Mojo's data pipe gives its producer the same `MOJO_RESULT_SHOULD_WAIT` and
/// `MOJO_HANDLE_SIGNAL_WRITABLE` (mojo/core/data_pipe_producer_dispatcher.cc).
public nonisolated protocol RemoteRdByteCarrier: AnyObject, Sendable {
    /// Opens the path. Called once; every event runs on `queue`, in order.
    func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void)
    /// Queues `bytes` after the bytes sent before; a failure is `.closed`. Never drops bytes for a full
    /// queue: the transport stops producing while ``isBackedUp``.
    func send(_ bytes: Data)
    /// True while the carrier holds its bound of bytes the path has not taken; a `.writable` event
    /// follows once it drained to half.
    var isBackedUp: Bool { get }
    /// Ends the path; sends after it are dropped.
    func cancel()
}
