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
    /// Frame `frame` finished decoding at `decodedAtMicros` (`DispatchTime` uptime) after
    /// `decodeMicros`: the source's decode feedback to the host and its stage ledger.
    func noteDecoded(frame: UInt32, decodeMicros: UInt32, decodedAtMicros: UInt64)
    /// Frame `frame` reached the glass at `presentedAtMicros` (`DispatchTime` uptime).
    func notePresented(frame: UInt32, presentedAtMicros: UInt64)
}

public nonisolated extension RemoteViewStreamSource {
    /// A source with no feedback channel or stage ledger ignores decode and present times.
    func noteDecoded(frame: UInt32, decodeMicros: UInt32, decodedAtMicros: UInt64) {}
    func notePresented(frame: UInt32, presentedAtMicros: UInt64) {}
}

/// A source whose pictures arrive already decoded (an RFB compatibility
/// host sends pixels, not video): the pane presents them as they come, with
/// no video decoder. `accessUnits()` stays empty for such a source.
public nonisolated protocol RemoteViewFrameSource: RemoteViewStreamSource {
    /// Pictures in display order, latest wins (bounded `bufferingNewest`).
    /// Finishes when the session ends.
    func decodedFrames() -> AsyncStream<RemoteDecodedFrame>
}

/// The remote cursor as the host reports it, in stream pixels (cap `cursor`:
/// the host leaves it out of the pictures). Shapes ride the control channel;
/// `shapeHash` names one, and `shape` is its image once it arrived.
public nonisolated struct RemoteCursorState: Sendable, Hashable {
    public var position: CGPoint
    public var visible: Bool
    public var shapeHash: UInt64?
    public var shape: RemoteCursorShape?

    public init(position: CGPoint, visible: Bool, shapeHash: UInt64? = nil, shape: RemoteCursorShape? = nil) {
        self.position = position
        self.visible = visible
        self.shapeHash = shapeHash
        self.shape = shape
    }
}
