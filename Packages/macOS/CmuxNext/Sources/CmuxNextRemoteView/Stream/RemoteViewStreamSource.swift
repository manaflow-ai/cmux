public import CoreGraphics
import Foundation

/// The transport-neutral input of the pane. The App adapts a `cmux.rd/1`
/// session (overlay datagrams, the DO relay, or a test) to this; the mock
/// (`MockRemoteStreamSource`) encodes synthetic frames with VideoToolbox.
///
/// Streams must be bounded (`bufferingNewest`): a slow decoder then loses
/// access units, which the pipeline sees as a frame gap and answers with
/// `requestKeyframe()` instead of showing frames that reference lost ones.
public nonisolated protocol RemoteViewStreamSource: AnyObject, Sendable {
    /// Complete access units in frame order. Finishes when the session ends.
    func accessUnits() -> AsyncStream<RemoteAccessUnit>
    /// Path, RTT, loss and session state; the first value arrives at once.
    func statusUpdates() -> AsyncStream<RemoteViewStatus>
    /// Remote cursor position and visibility (view mode overlay, RD6).
    func cursorUpdates() -> AsyncStream<RemoteCursorState>
    /// Asks the host for an IDR: after a decode error or a frame gap.
    func requestKeyframe()
}

/// The remote cursor as the host reports it, in stream pixels. Shapes ride
/// the control channel; `shapeHash` names a cached image.
public nonisolated struct RemoteCursorState: Sendable, Hashable {
    public var position: CGPoint
    public var visible: Bool
    public var shapeHash: UInt64?

    public init(position: CGPoint, visible: Bool, shapeHash: UInt64? = nil) {
        self.position = position
        self.visible = visible
        self.shapeHash = shapeHash
    }
}
