import Foundation

extension CMUXCLI {
    func readScreenPayload(
        client: SocketClient,
        params: [String: Any]
    ) throws -> [String: Any] {
        var readParams = params
        if readParams["start_if_needed"] == nil {
            readParams["start_if_needed"] = true
        }
        return try client.sendV2(method: "surface.read_text", params: readParams)
    }

    func contentSearchTerminalText(
        workspaceId: String,
        client: SocketClient
    ) -> String? {
        guard let payload = try? client.sendV2(method: "surface.read_text", params: [
            "workspace_id": workspaceId,
            "start_if_needed": false,
        ]) else {
            return nil
        }
        return payload["text"] as? String
    }
}
