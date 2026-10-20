#if DEBUG
import Foundation

extension MobileHostConnectionRegistry {
    /// Closes one selected mobile transport, or every mobile transport when
    /// no id is supplied, through the production connection-owned close path.
    func debugCloseConnections(connectionID: UUID?) async -> [UUID] {
        let selected: [MobileHostConnection]
        if let connectionID {
            selected = connection(id: connectionID).map { [$0] } ?? []
        } else {
            selected = snapshot()
        }
        let ordered = selected.sorted {
            $0.connectionID.uuidString < $1.connectionID.uuidString
        }
        for connection in ordered {
            await connection.close(reason: "debug transport disconnect")
        }
        return ordered.map(\.connectionID)
    }
}
#endif
