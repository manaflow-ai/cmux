import CmuxInstallAuthCore
import CryptoKit
import Foundation

/// The API Worker routes a Mac install touches: `user.ensure`,
/// `install.register`, the challenge and token mint, and `host.enroll`.
actor FakeAPI: InstallAuthTransport {
    var registrations: [[String: String]] = []
    var enrollments: [(name: String, key: String, bearer: String?)] = []
    var installKey: P256.Signing.PublicKey?
    var mints = 0
    let environment = "staging"

    nonisolated func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        try await handle(path, json, bearer)
    }

    private func reply(_ object: [String: Any], _ status: Int = 200) throws -> (status: Int, body: Data) {
        (status, try JSONSerialization.data(withJSONObject: object))
    }

    private func handle(_ path: String, _ json: Data, _ bearer: String?) throws -> (status: Int, body: Data) {
        let body = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        switch path {
        case "/v1/ops":
            let params = body["params"] as! [String: Any]
            switch body["op"] as! String {
            case "user.ensure":
                return try reply(["ok": true, "value": ["id": "user_1", "stack_user_id": "stack_1"]])
            case "install.register":
                registrations.append(["kind": params["kind"] as? String ?? "", "platform": params["platform"] as? String ?? "",
                                      "op_classes": params["op_classes"] == nil ? "default" : "narrowed"])
                let jwk = params["public_jwk"] as! [String: String]
                let x = Data(base64URLEncoded: jwk["x"]!)!, y = Data(base64URLEncoded: jwk["y"]!)!
                installKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
                return try reply(["ok": true, "value": ["id": "inst_mac1", "kind": params["kind"]!]])
            case "host.enroll":
                enrollments.append((params["name"] as! String, body["idempotency_key"] as! String, bearer))
                return try reply(["ok": true, "value": ["id": "host_m1", "name": params["name"]!, "platform": "macos"]])
            default:
                return try reply(["ok": false, "error": ["code": "validation.invalid", "message": "unknown op"]])
            }
        case "/v1/auth/challenge":
            return try reply(["nonce": String(repeating: "a", count: 32),
                              "message_prefix": "cmux-auth-v1\n\(environment)\n\(body["install"] as! String)\n", "expires_at": 0])
        case "/v1/auth/token":
            guard let key = installKey, let raw = Data(base64URLEncoded: body["signature"] as! String),
                  let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
                  key.isValidSignature(signature, for: Data("cmux-auth-v1\n\(environment)\n\(body["install"] as! String)\n\(body["nonce"] as! String)".utf8))
            else { return try reply(["code": "auth.forbidden"], 403) }
            mints += 1
            let payload = try JSONSerialization.data(withJSONObject: ["iss": "https://cmux-api/\(environment)", "n": mints])
            return try reply(["access_token": "e30.\(payload.base64URLEncoded).c2ln",
                              "expires_at": Date().addingTimeInterval(600).timeIntervalSince1970 * 1000])
        default:
            return try reply([:], 404)
        }
    }
}
