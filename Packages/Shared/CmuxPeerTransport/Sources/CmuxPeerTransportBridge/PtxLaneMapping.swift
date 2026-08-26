import CmuxIrohTransport
import CmuxPeerTransport
import Foundation

extension PtxLaneDescriptor {
    /// The legacy lane this descriptor names, validated (resource IDs are
    /// bounded opaque identifiers; anything else rejects the stream).
    public func legacyLane() throws -> CmxIrohLane {
        switch lane {
        case .control:
            return .control
        case .serverEvents:
            return .serverEvents(cursor: cursor)
        case .terminal:
            guard let resourceID else { throw CmxIrohResourceIDError.invalidValue }
            return .terminal(resourceID: try CmxIrohResourceID(resourceID), cursor: cursor)
        case .artifact:
            guard let resourceID else { throw CmxIrohResourceIDError.invalidValue }
            return .artifact(resourceID: try CmxIrohResourceID(resourceID), offset: offset ?? 0)
        case .simulatorStream:
            guard let resourceID else { throw CmxIrohResourceIDError.invalidValue }
            return .simulatorStream(resourceID: try CmxIrohResourceID(resourceID))
        }
    }

    public init(legacy lane: CmxIrohLane) {
        switch lane {
        case .control:
            self.init(lane: .control)
        case .serverEvents(let cursor):
            self.init(lane: .serverEvents, cursor: cursor)
        case .terminal(let resourceID, let cursor):
            self.init(lane: .terminal, resourceID: resourceID.value, cursor: cursor)
        case .artifact(let resourceID, let offset):
            self.init(lane: .artifact, resourceID: resourceID.value, offset: offset)
        case .simulatorStream(let resourceID):
            self.init(lane: .simulatorStream, resourceID: resourceID.value)
        }
    }
}
