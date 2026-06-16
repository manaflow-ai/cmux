import Foundation
import Darwin

extension CMUXCLI {
    func readScreenPayload(
        client: SocketClient,
        params: [String: Any]
    ) throws -> [String: Any] {
        var readParams = params
        if readParams["start_if_needed"] == nil {
            readParams["start_if_needed"] = true
        }
        var readAttempt = 0
        while true {
            do {
                return try client.sendV2(method: "surface.read_text", params: readParams)
            } catch let error as CLIError
                where error.message.hasPrefix("terminal_not_ready:") && readAttempt < 60 {
                readAttempt += 1
                usleep(100_000)
            }
        }
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
