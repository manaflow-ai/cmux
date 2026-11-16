import CoreGraphics
import Foundation

/// A host `CursorPos` datagram (rd cap `cursor`, cmux-rd-proto `cursor.rs`):
/// the host leaves the pointer out of the picture and reports it here, so a
/// viewer in control shows only its own pointer and a view-only viewer draws
/// the host's. Header included: 16 bytes, then `u32 seq`, `u32 x`, `u32 y`
/// (stream pixels), `u8 visible`, little-endian.
/// The hello cap that asks for them is `RemoteRdStreamTransport.cursorCap`.
nonisolated struct RemoteRdCursorDatagram: Equatable {
    let seq: UInt32
    let state: RemoteCursorState

    init?(_ datagram: Data) {
        let bytes = [UInt8](datagram)
        let headerLength = 16
        guard bytes.count == headerLength + 13, bytes[1] == 6, bytes[headerLength + 12] <= 1 else { return nil }
        func u32(_ at: Int) -> UInt32 {
            let i = headerLength + at
            return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        seq = u32(0)
        state = RemoteCursorState(position: CGPoint(x: Int(u32(4)), y: Int(u32(8))), visible: bytes[headerLength + 12] == 1)
    }

    /// Latest wins: true when this seq comes after `last` (wrapping), or nothing came yet.
    func isNewer(than last: UInt32?) -> Bool {
        guard let last else { return true }
        let ahead = seq &- last
        return ahead != 0 && ahead < UInt32.max / 2
    }
}
