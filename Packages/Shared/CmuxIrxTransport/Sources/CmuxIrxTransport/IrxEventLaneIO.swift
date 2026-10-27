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
public struct IrxSurfaceEventLaneProtocol: Sendable {
    public init() {}

    /// `mobile.events.subscribe` parameter a client sends to opt in, and the
    /// acknowledgement key a host echoes when it granted surface lanes.
    public let subscribeParameterKey = "surface_event_lanes"
    public let subscribeParameterValue = "v1"
    let resourcePrefix = "terminal:"

    public func descriptor(surfaceID: String) -> IrxLaneDescriptor {
        IrxLaneDescriptor(
            lane: .events,
            resource: resourcePrefix + normalizedSurfaceID(surfaceID)
        )
    }

    /// The surface a lane carries, or nil for the shared events lane.
    public func surfaceID(of descriptor: IrxLaneDescriptor) -> String? {
        guard descriptor.lane == .events,
              let resource = descriptor.resource,
              resource.hasPrefix(resourcePrefix) else { return nil }
        let surfaceID = String(resource.dropFirst(resourcePrefix.count))
        return surfaceID.isEmpty ? nil : surfaceID
    }

    public func normalizedSurfaceID(_ surfaceID: String) -> String {
        surfaceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
