import CoreGraphics
import Foundation

/// The remote cursor as metadata (cap `cursor`, cmux-rd-proto `cursor.rs`): turns
/// `cursor_shape` control messages and `CursorPos` datagrams into cursor states.
/// Positions are latest wins (an older sequence number is dropped); shapes are
/// cached by id, so a position names its shape and a shape that arrives after its
/// position updates the state it named.
nonisolated struct RemoteCursorFeed {
    /// `DatagramKind::CursorPos`.
    static let datagramKind: UInt8 = 6
    /// cmux-rd-proto `HEADER_LEN` and `CURSOR_POS_LEN`.
    static let headerLength = 16
    static let payloadLength = 13
    /// Shapes kept (the host re-sends one it evicted from its own memory of 64).
    static let maxShapes = 64

    enum Result: Equatable {
        /// Not a cursor datagram.
        case notCursor
        /// A cursor datagram older than the newest applied, or malformed.
        case dropped
        case state(RemoteCursorState)
    }

    private var shapes: [UInt32: RemoteCursorShape] = [:]
    private var shapeOrder: [UInt32] = []
    private var seq: UInt32?
    private(set) var current: RemoteCursorState?

    /// A `cursor_shape`: cached; returns the current state when it named this shape.
    mutating func receive(shape: RemoteCursorShape) -> RemoteCursorState? {
        if shapes[shape.id] == nil {
            if shapeOrder.count == Self.maxShapes {
                shapes.removeValue(forKey: shapeOrder.removeFirst())
            }
            shapeOrder.append(shape.id)
        }
        shapes[shape.id] = shape
        guard var state = current, state.shapeHash == UInt64(shape.id), state.shape != shape else { return nil }
        state.shape = shape
        current = state
        return state
    }

    /// One datagram from the host.
    mutating func receive(datagram: Data) -> Result {
        let bytes = [UInt8](datagram)
        guard bytes.count >= 2, bytes[1] == Self.datagramKind else { return .notCursor }
        guard bytes.count == Self.headerLength + Self.payloadLength, bytes[0] >> 4 == 1 else { return .dropped }
        let frame = Self.u32(bytes, 4)
        if let seq, !Self.isNewer(frame, than: seq) { return .dropped }
        let p = Self.headerLength
        let id = Self.u32(bytes, p)
        let x = Int32(bitPattern: Self.u32(bytes, p + 4))
        let y = Int32(bitPattern: Self.u32(bytes, p + 8))
        let flags = bytes[p + 12]
        guard flags & ~0b1 == 0 else { return .dropped }
        seq = frame
        let state = RemoteCursorState(position: CGPoint(x: Double(x), y: Double(y)), visible: flags & 1 != 0,
                                      shapeHash: id == 0 ? nil : UInt64(id), shape: id == 0 ? nil : shapes[id])
        // Until a named shape arrives, keep wearing the last one (no flash to the arrow).
        var shown = state
        if shown.shape == nil, id != 0, let previous = current?.shape { shown.shape = previous }
        current = shown
        return .state(shown)
    }

    /// cmux-rd-proto `cursor_seq_newer`.
    static func isNewer(_ seq: UInt32, than last: UInt32) -> Bool {
        seq != last && seq &- last < 1 << 31
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
