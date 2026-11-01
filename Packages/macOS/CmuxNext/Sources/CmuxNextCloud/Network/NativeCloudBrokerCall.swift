import Foundation

/// The app supplies its own fresh proof; none of these credentials comes from the link.
struct NativeCloudBrokerCall: Encodable {
    struct Params: Encodable {
        let host: String
        let services: [NativeCloudBrokerRequest.Service]?
        let native_proof: NativeDeviceProof?
    }
    let op: String
    let params: Params
}

enum NativeCloudBrokerReply {
    /// Strip the owner envelope and all refusal text. Identity failures throw before this point.
    static func encode(_ response: (status: Int, body: Data), request: NativeCloudBrokerRequest) throws -> Data {
        guard response.body.count <= 60_000,
              let body = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw NativeDeviceEnrollmentError.invalidIdentity
        }
        var reply: [String: Any] = ["version": 1, "id": request.id]
        if let refusal = body["error"] as? [String: Any], let code = refusal["code"] as? String {
            guard body["value"] == nil else { throw NativeDeviceEnrollmentError.invalidIdentity }
            reply["error"] = ["code": try safeCode(code)]
        } else if response.status != 200 {
            reply["error"] = ["code": try safeCode(body["code"] as? String ?? "owner.unreachable")]
        } else {
            guard body["error"] == nil, let value = body["value"] as? [String: Any],
                  value["host"] as? String == request.host else { throw NativeDeviceEnrollmentError.invalidIdentity }
            switch request.op {
            case .connectInfo:
                guard body["op"] as? String == request.op.rawValue else { throw NativeDeviceEnrollmentError.invalidIdentity }
            case .linkToken:
                guard body["ok"] as? Bool == true, let services = value["services"] as? [String],
                      Set(services) == Set(request.services?.map(\.rawValue) ?? []), services.count == request.services?.count,
                      let token = value["token"] as? String, !token.isEmpty else { throw NativeDeviceEnrollmentError.invalidIdentity }
            }
            reply["value"] = value
        }
        return try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
    }

    private static func safeCode(_ code: String) throws -> String {
        guard !code.isEmpty, code.utf8.count <= 80,
              code.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || "._".contains($0)) }) else {
            throw NativeDeviceEnrollmentError.invalidIdentity
        }
        return code
    }
}
