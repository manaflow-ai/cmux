import CmuxIrohTransport
import Foundation

/// Errors from encoding a legacy lane into a raw-stream preamble or parsing
/// one back.
public enum BridgeLaneDescriptorError: Error, Equatable, Sendable {
    case invalidDescriptor
    /// The descriptor did not encode. Failing closed beats silently dialing
    /// a control-lane preamble for a terminal/artifact stream: the acceptor
    /// would route the bytes to the wrong service.
    case unencodableDescriptor
}

/// The `raw.open` preamble carried by every bridged lane: a compact JSON
/// object standing in for the legacy `CMUXIRH1` binary stream header. The
/// preamble names the lane; every byte after the handshake frame is the
/// legacy in-lane payload, verbatim.
public enum BridgeLaneDescriptor {
    private struct Descriptor: Codable {
        var lane: String
        var resourceID: String?
        var cursor: UInt64?
        var offset: UInt64?

        enum CodingKeys: String, CodingKey {
            case lane
            case resourceID = "resource_id"
            case cursor
            case offset
        }
    }

    private static let control = "control"
    private static let serverEvents = "server_events"
    private static let terminal = "terminal"
    private static let artifact = "artifact"
    private static let simulatorStream = "simulator_stream"

    public static func preamble(for lane: CmxIrohLane) throws -> String {
        let descriptor: Descriptor
        switch lane {
        case .control:
            descriptor = Descriptor(lane: control)
        case .serverEvents(let cursor):
            descriptor = Descriptor(lane: serverEvents, cursor: cursor)
        case .terminal(let resourceID, let cursor):
            descriptor = Descriptor(lane: terminal, resourceID: resourceID.value, cursor: cursor)
        case .artifact(let resourceID, let offset):
            descriptor = Descriptor(lane: artifact, resourceID: resourceID.value, offset: offset)
        case .simulatorStream(let resourceID):
            descriptor = Descriptor(lane: simulatorStream, resourceID: resourceID.value)
        }
        guard let data = try? JSONEncoder().encode(descriptor),
            let text = String(data: data, encoding: .utf8)
        else {
            // Descriptor is a flat value struct, so this should be
            // unreachable — but a silent control-lane fallback would route
            // the stream's bytes to the wrong service. Fail closed.
            throw BridgeLaneDescriptorError.unencodableDescriptor
        }
        return text
    }

    public static func lane(fromPreamble preamble: String) throws -> CmxIrohLane {
        guard let data = preamble.data(using: .utf8),
            let descriptor = try? JSONDecoder().decode(Descriptor.self, from: data)
        else { throw BridgeLaneDescriptorError.invalidDescriptor }
        switch descriptor.lane {
        case control:
            return .control
        case serverEvents:
            return .serverEvents(cursor: descriptor.cursor)
        case terminal:
            guard let id = try? CmxIrohResourceID(descriptor.resourceID ?? "") else {
                throw BridgeLaneDescriptorError.invalidDescriptor
            }
            return .terminal(resourceID: id, cursor: descriptor.cursor)
        case artifact:
            guard let id = try? CmxIrohResourceID(descriptor.resourceID ?? ""),
                let offset = descriptor.offset
            else { throw BridgeLaneDescriptorError.invalidDescriptor }
            return .artifact(resourceID: id, offset: offset)
        case simulatorStream:
            guard let id = try? CmxIrohResourceID(descriptor.resourceID ?? "") else {
                throw BridgeLaneDescriptorError.invalidDescriptor
            }
            return .simulatorStream(resourceID: id)
        default:
            throw BridgeLaneDescriptorError.invalidDescriptor
        }
    }
}
