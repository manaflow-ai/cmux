public import Foundation

/// Carries a per-terminal event lane's identity to the phone's event decoder.
///
/// The phone reads each terminal's event lane separately but decodes all of
/// them from one merged byte stream. The lane hub stamps a scope marker
/// directly before every frame it forwards from a terminal's lane, and the
/// decoder checks the one frame that follows a marker against it, so an event
/// routed onto the wrong lane is refused instead of drawn into another
/// terminal. The terminal the event did name misses a revision and resyncs
/// through its own chain.
///
/// A marker is a 17-byte binary frame (a zero tag plus the terminal's UUID),
/// never JSON, and it scopes only the frame the hub writes immediately after
/// it. Bytes received from the network can therefore never open, move or
/// close a scope: a host-sent frame that mimics a marker only rescopes the
/// hub's own next marker, which every event frame is preceded by. Markers
/// exist only inside the phone; they never cross the network.
public struct MobileEventLaneScope: Sendable {
    public static let markerByteCount = 17
    private static let markerTag: UInt8 = 0

    public init() {}

    /// A framed marker scoping the next frame to `surfaceID`.
    public func marker(surfaceID: UUID) -> Data {
        var payload = Data([Self.markerTag])
        payload.append(contentsOf: surfaceID.uuidBytes)
        return (try? MobileSyncFrameCodec.encodeFrame(payload)) ?? Data()
    }

    /// Interleaves a marker before each complete frame of `block` (whole
    /// frames, as the lane hub's aligner returns them). A lane whose resource
    /// is not a terminal UUID is forwarded unscoped.
    public func scoped(_ block: Data, surfaceID: String) -> Data {
        guard let surface = UUID(uuidString: surfaceID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return block
        }
        let mark = marker(surfaceID: surface)
        var scoped = Data(capacity: block.count + mark.count * 4)
        var offset = block.startIndex
        while block.distance(from: offset, to: block.endIndex) >= MobileSyncFrameCodec.headerByteCount {
            var length = 0
            for byte in block[offset..<block.index(offset, offsetBy: MobileSyncFrameCodec.headerByteCount)] {
                length = (length << 8) | Int(byte)
            }
            let frameByteCount = MobileSyncFrameCodec.headerByteCount + length
            guard block.distance(from: offset, to: block.endIndex) >= frameByteCount else { break }
            scoped.append(mark)
            scoped.append(block[offset..<block.index(offset, offsetBy: frameByteCount)])
            offset = block.index(offset, offsetBy: frameByteCount)
        }
        // The aligner only returns whole frames; any tail would be malformed.
        // Forwarding it unscoped keeps the failure visible to the decoder.
        if offset < block.endIndex { scoped.append(block[offset...]) }
        return scoped
    }

    /// The terminal a marker frame scopes the next frame to, or nil when the
    /// frame payload is not a marker (JSON never starts with a zero byte).
    public func markerScope(inPayload payload: Data) -> UUID? {
        guard payload.count == Self.markerByteCount,
              payload.first == Self.markerTag else { return nil }
        return UUID(uuidBytes: Array(payload.dropFirst()))
    }

    /// Whether an event payload decoded inside `scope` belongs to that
    /// terminal.
    public func eventBelongs(payload: Any?, toScope scope: UUID) -> Bool {
        guard let payload = payload as? [String: Any],
              let surfaceID = payload["surface_id"] as? String,
              let surface = UUID(uuidString: surfaceID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return surface == scope
    }
}
