import CMUXMobileCore
import Foundation

extension LivenessHostRouter {
    func setCapabilities(_ capabilities: [String]) {
        self.capabilities = capabilities
    }

    func setAttachTicketMacDeviceID(_ macDeviceID: String) {
        attachTicketMacDeviceID = macDeviceID
    }

    func setHostIdentity(deviceID: String?, instanceTag: String?, displayName: String? = nil) {
        macDeviceID = deviceID
        macInstanceTag = instanceTag
        macDisplayName = displayName
    }

    func failRequests(method: String, code: String?, message: String) {
        requestFailures[method] = (code, message)
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
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}
