#if DEBUG
import Foundation

extension MobileHostConnectionRegistry {
    /// Resolves the exact connection, then asks that actor to validate the
    /// complete current readiness claim without introducing parallel state.
    func debugValidateReadiness(
        connectionID: UUID,
        clientID: String,
        launchID: String,
        streamID: String,
        transport: String
    ) async -> Bool {
        guard let connection = connection(id: connectionID) else {
            return false
        }
        return await connection.debugValidateReadiness(
            connectionID: connectionID,
            clientID: clientID,
            launchID: launchID,
            streamID: streamID,
            transport: transport
        )
    }

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
