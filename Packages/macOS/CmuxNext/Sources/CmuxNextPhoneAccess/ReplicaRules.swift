internal import CCmuxLayoutReducerFFI
import Foundation

/// The cloud host replica follower's decisions in Rust (`cmux-phone-core`'s `replica_*` requests over the app FFI's
/// `phone` op). Swift reads the defaults, the token and the computer name, and makes the daemon calls.
nonisolated enum ReplicaRules {
    /// One `phone` request's reply decoded as `T`; nil when Rust does not answer or answers something else.
    static func ask<T: Decodable>(_ type: T.Type, _ op: String, _ fields: [String: Any] = [:]) -> T? {
        var body = fields
        body["op"] = op
        guard JSONSerialization.isValidJSONObject(body), let request = try? JSONSerialization.data(withJSONObject: body),
              let reply = call(request) else { return nil }
        return try? JSONDecoder().decode(T.self, from: reply)
    }

    /// The defaults keys (`replica_keys`).
    struct Keys: Decodable {
        let published: String
        let purgeAsked: String

        enum CodingKeys: String, CodingKey {
            case published = "published_key"
            case purgeAsked = "purge_asked_key"
        }
    }

    /// One step's answer (`replica_apply`, `replica_purge`): `none`, `clear`, `lease`, `status`, `forget`,
    /// `lease_then_purge`.
    struct Step: Decodable {
        let action: String
        let invalidate: Bool?
        let markPurgeAsked: Int64?

        enum CodingKeys: String, CodingKey {
            case action, invalidate
            case markPurgeAsked = "mark_purge_asked"
        }
    }

    /// `cloud-host-replica-set`'s fields (`replica_lease`); `lease` nil when no lease goes.
    struct Lease: Decodable {
        struct Fields: Decodable {
            let apiBaseURL: String
            let installToken: String
            let expiresAt: UInt64
            let clientVersion: String?
            let hostName: String

            enum CodingKeys: String, CodingKey {
                case apiBaseURL = "api_base_url"
                case installToken = "install_token"
                case expiresAt = "expires_at"
                case clientVersion = "client_version"
                case hostName = "host_name"
            }
        }

        let lease: Fields?
    }

    private static func call(_ request: Data) -> Data? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = request.withUnsafeBytes { bytes in
                "phone".withCString { op in
                    output.withUnsafeMutableBytes { out in
                        cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, request.count, op,
                                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity { capacity = length; continue }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return Data(output.prefix(length))
        }
        return nil
    }
}
