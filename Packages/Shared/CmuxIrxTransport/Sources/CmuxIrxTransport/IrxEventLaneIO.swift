public import Foundation

/// Write half of one server->client event lane. ``IrxStreamWriter`` is the
/// production conformer; tests substitute in-memory lanes.
public protocol IrxEventLaneWriting: Sendable {
    func write(_ data: Data) async throws
    func setPriority(_ priority: Int32) async throws
    func finish() async
    func reset(errorCode: UInt64) async
}

/// Read half of one server->client event lane. ``IrxStreamReader`` is the
/// production conformer; tests substitute in-memory lanes.
public protocol IrxEventLaneReading: Sendable {
    /// Whatever bytes are available, or nil on EOF.
    func readRaw() async throws -> Data?
    func stop(errorCode: UInt64) async
}

extension IrxStreamWriter: IrxEventLaneWriting {}
extension IrxStreamReader: IrxEventLaneReading {}

/// Wire vocabulary for per-surface event lanes.
///
/// A surface lane is an `events` lane whose descriptor names the terminal it
/// carries (`terminal:<surface-id>`). The shared events lane has no resource,
/// so a peer that predates surface lanes never confuses the two. The Mac only
/// opens surface lanes after the phone advertised ``subscribeParameterValue``
/// in `mobile.events.subscribe`, because an older phone accepts exactly one
/// uni stream and would never read a second one.
public enum IrxSurfaceEventLaneProtocol {
    /// `mobile.events.subscribe` parameter a client sends to opt in, and the
    /// acknowledgement key a host echoes when it granted surface lanes.
    public static let subscribeParameterKey = "surface_event_lanes"
    public static let subscribeParameterValue = "v1"
    static let resourcePrefix = "terminal:"

    public static func descriptor(surfaceID: String) -> IrxLaneDescriptor {
        IrxLaneDescriptor(
            lane: .events,
            resource: resourcePrefix + normalizedSurfaceID(surfaceID)
        )
    }

    /// The surface a lane carries, or nil for the shared events lane.
    public static func surfaceID(of descriptor: IrxLaneDescriptor) -> String? {
        guard descriptor.lane == .events,
              let resource = descriptor.resource,
              resource.hasPrefix(resourcePrefix) else { return nil }
        let surfaceID = String(resource.dropFirst(resourcePrefix.count))
        return surfaceID.isEmpty ? nil : surfaceID
    }

    public static func normalizedSurfaceID(_ surfaceID: String) -> String {
        surfaceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Splits a lane's byte stream at mobile-sync frame boundaries (4-byte
/// big-endian length + payload). Readers that merge several lanes into one
/// consumer must only forward whole frames, or bytes from two lanes would
/// interleave inside a frame.
struct IrxEventFrameAligner: Sendable {
    enum Failure: Error, Equatable {
        case frameTooLarge(Int)
    }

    static let headerByteCount = 4

    let maximumFrameByteCount: Int
    private var buffer = Data()

    init(maximumFrameByteCount: Int) {
        self.maximumFrameByteCount = maximumFrameByteCount
    }

    var hasPartialFrame: Bool { !buffer.isEmpty }

    /// Appends `chunk` and returns every complete frame now available, still
    /// framed, as one contiguous block; nil when no frame completed.
    mutating func append(_ chunk: Data) throws -> Data? {
        buffer.append(chunk)
        var consumed = 0
        while buffer.count - consumed >= Self.headerByteCount {
            let start = buffer.startIndex + consumed
            var length = 0
            for byte in buffer[start..<(start + Self.headerByteCount)] {
                length = (length << 8) | Int(byte)
            }
            guard length <= maximumFrameByteCount else {
                throw Failure.frameTooLarge(length)
            }
            let frameByteCount = Self.headerByteCount + length
            guard buffer.count - consumed >= frameByteCount else { break }
            consumed += frameByteCount
        }
        guard consumed > 0 else { return nil }
        let complete = Data(buffer.prefix(consumed))
        buffer.removeFirst(consumed)
        return complete
    }
}
