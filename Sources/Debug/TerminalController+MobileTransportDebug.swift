#if DEBUG
import Foundation

extension TerminalController {
    nonisolated func v2DebugMobileTransportDisconnect(
        id: Any?,
        params: [String: Any]
    ) -> String {
        let selectedConnectionID: UUID?
        if let rawConnectionID = params["connection_id"] {
            guard let value = rawConnectionID as? String,
                  let parsed = UUID(uuidString: value) else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: "connection_id must be a UUID"
                )
            }
            selectedConnectionID = parsed
        } else {
            selectedConnectionID = nil
        }
        return v2AsyncResultCall(id: id, timeoutSeconds: 10) {
            let closed = await MobileHostConnectionRegistry.shared
                .debugCloseConnections(connectionID: selectedConnectionID)
            return .ok([
                "closed_connection_ids": closed.map(\.uuidString),
                "closed_count": closed.count,
            ])
        }
    }
}
#endif
