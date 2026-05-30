import Foundation

/// Parameters for opening an output stream subscription.
///
/// `lastEventID` is the SSE `Last-Event-ID` value for resume per D6.
/// When non-`nil`, the Phase 2 stream service replays from
/// `lastEventID + 1`; events older than the per-subscriber ring's
/// oldest retained `seq` are silently dropped (the client observes a
/// monotonic JUMP in `seq`, per D6).
public struct StreamSubscriptionOptions: Sendable, Hashable {
    /// Surface to subscribe to.
    public let handle: SurfaceHandle
    /// Whether the subscriber wants raw bytes or cell-grid snapshots.
    public let mode: StreamMode
    /// Optional SSE `Last-Event-ID` value to resume from. `nil` starts
    /// at the next emitted event.
    public let lastEventID: UInt64?

    /// Creates a new subscription request.
    ///
    /// - Parameters:
    ///   - handle: Target surface.
    ///   - mode: ``StreamMode/raw`` or ``StreamMode/cells``.
    ///   - lastEventID: SSE resume cursor; defaults to `nil`.
    public init(handle: SurfaceHandle, mode: StreamMode, lastEventID: UInt64? = nil) {
        self.handle = handle
        self.mode = mode
        self.lastEventID = lastEventID
    }
}
