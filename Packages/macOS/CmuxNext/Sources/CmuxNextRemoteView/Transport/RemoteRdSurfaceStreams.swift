import Foundation

/// What an rb/1 service body does to the session's display streams
/// (remote-tab-protocol.md section 2: popup surfaces stream on their own rd
/// streams). The transport applies it on its queue before the body reaches
/// the service stream, so a surface's units are buffered by the time its
/// view asks for them.
nonisolated enum RemoteRdSurfaceStreamChange: Equatable {
    /// `rb.surface.show {surface, stream}`.
    case show(surface: UInt32, stream: UInt16)
    /// `rb.surface.hide {surface}`.
    case hide(surface: UInt32)

    init?(_ body: RemoteRdJSON) {
        guard case let .object(fields) = body, case let .string(t)? = fields["t"],
              let surface = fields["surface"]?.unsigned.flatMap({ UInt32(exactly: $0) }) else { return nil }
        switch t {
        case "rb.surface.show":
            // Stream 0 is the page; a surface never streams there.
            guard let stream = fields["stream"]?.unsigned.flatMap({ UInt16(exactly: $0) }), stream != 0 else { return nil }
            self = .show(surface: surface, stream: stream)
        case "rb.surface.hide":
            self = .hide(surface: surface)
        default:
            return nil
        }
    }
}

/// The popup streams the transport has open, by surface, with the units
/// each one buffered for its view. Lives in the transport's state mutex.
nonisolated struct RemoteRdSurfaceStreams {
    struct Open {
        var surface: UInt32
        /// Handed out once, to the surface's decode pipeline.
        var units: AsyncStream<RemoteAccessUnit>?
        let continuation: AsyncStream<RemoteAccessUnit>.Continuation
    }

    private(set) var open: [UInt16: Open] = [:]

    /// The stream that carries `surface`, if open.
    func stream(of surface: UInt32) -> UInt16? {
        open.first { $0.value.surface == surface }?.key
    }

    /// Starts buffering units of `stream` for `surface`.
    mutating func start(stream: UInt16, surface: UInt32) {
        open.removeValue(forKey: stream)?.continuation.finish()
        // Bounded like the page's units: a slow decoder loses units, sees the gap and asks for a keyframe.
        let (units, continuation) = AsyncStream.makeStream(of: RemoteAccessUnit.self, bufferingPolicy: .bufferingNewest(8))
        open[stream] = Open(surface: surface, units: units, continuation: continuation)
    }

    /// Ends `stream`'s units.
    mutating func end(stream: UInt16) {
        open.removeValue(forKey: stream)?.continuation.finish()
    }

    mutating func endAll() {
        for entry in open.values { entry.continuation.finish() }
        open.removeAll()
    }

    func yield(_ unit: RemoteAccessUnit, stream: UInt16) {
        open[stream]?.continuation.yield(unit)
    }

    /// The units of `stream`, once; nil when it is not open or was taken.
    mutating func take(stream: UInt16) -> AsyncStream<RemoteAccessUnit>? {
        defer { open[stream]?.units = nil }
        return open[stream]?.units
    }
}

nonisolated extension RemoteRdJSON {
    /// A non-negative integer value (JSON numbers may arrive as doubles).
    var unsigned: UInt64? {
        switch self {
        case let .int(value): UInt64(exactly: value)
        case let .double(value): UInt64(exactly: value)
        default: nil
        }
    }
}
