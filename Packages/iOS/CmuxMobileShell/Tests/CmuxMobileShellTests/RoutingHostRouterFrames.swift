import CMUXMobileCore
import CmuxMobileRPC
import Foundation

extension RoutingHostRouter {
    static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(
            JSONSerialization.data(withJSONObject: envelope)
        )
    }

    static func errorFrame(
        id: String?,
        code: String? = nil,
        message: String
    ) throws -> Data {
        var error: [String: Any] = ["message": message]
        if let code { error["code"] = code }
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": false,
            "error": error,
        ]
        return try MobileSyncFrameCodec.encodeFrame(
            JSONSerialization.data(withJSONObject: envelope)
        )
    }
}
