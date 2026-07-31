#if DEBUG
import Foundation

extension MobileHostConnectionRegistry {
    /// Closes one selected mobile transport, or every mobile transport when
    /// no id is supplied, through the connection-owned production close path.
    func debugCloseConnections(connectionID: UUID?) async -> [UUID] {
        let selected: [(UUID, MobileHostConnection)]
        if let connectionID, let connection = connection(id: connectionID) {
            selected = [(connectionID, connection)]
        } else if connectionID == nil {
            selected = identifiedSnapshot()
        } else {
            selected = []
        }
        let ordered = selected.sorted { $0.0.uuidString < $1.0.uuidString }
        for (_, connection) in ordered {
            await connection.close(reason: "debug transport disconnect")
        }
        return ordered.map(\.0)
    }
}
#endif
