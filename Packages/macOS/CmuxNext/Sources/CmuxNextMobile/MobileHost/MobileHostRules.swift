internal import CCmuxLayoutReducerFFI
import Foundation

/// The iPhone host's rules in Rust (`cmux-mobile-host-core`, the app FFI's `mobile_host` op): the
/// phones' acpmux credentials, the test pairing seed's match, the dev auto-approve's tags and the
/// phones' acpmux record names. Swift reads files, the Keychain and sockets and passes what they hold.
public enum MobileHostRules {
    /// One `mobile_host` request (`op` plus `fields`); the reply's object. Nil when Rust does not answer.
    public static func ask(_ op: String, _ fields: [String: Any] = [:]) -> [String: Any]? {
        var body = fields
        body["op"] = op
        // A NaN or infinite number raises in JSONSerialization; such a request has no answer.
        guard JSONSerialization.isValidJSONObject(body), let request = try? JSONSerialization.data(withJSONObject: body),
              let reply = call(request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }

    private static func call(_ request: Data) -> Data? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = request.withUnsafeBytes { bytes in
                "mobile_host".withCString { op in
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
