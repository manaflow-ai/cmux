import Foundation
import CmuxVNC

/// A stand-in for cmux-vnc's rules (the real ones and their known answers are tested in Rust,
/// cmux-tui/crates/cmux-vnc): enough of `vnc_version` and the security choice to drive the
/// Swift handshake, and a password "response" that is not DES but agrees between this client
/// and the demo server (whose own ops are FixtureDemoRules). No Apple DH.
extension VNCRules {
    static let fixture = VNCRules { operation, request in
        let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] ?? [:]
        func answer(_ value: Any) -> Data? { try? JSONSerialization.data(withJSONObject: value) }
        func bytes(_ key: String) -> [UInt8] { (object[key] as? String).flatMap { Data(base64Encoded: $0) }.map(Array.init) ?? [] }
        switch operation {
        case "vnc_version":
            let banner = String(decoding: bytes("banner"), as: UTF8.self)
            guard banner.count == 12, banner.hasPrefix("RFB 003."), banner.hasSuffix("\n"),
                  let server = Int(banner.dropFirst(8).prefix(3)) else { return answer(NSNull()) }
            let minor = server >= 8 ? 8 : server == 7 ? 7 : 3
            return answer(["serverMinor": server, "minor": minor,
                           "reply": Data("RFB 003.00\(minor)\n".utf8).base64EncodedString()])
        case "vnc_security_choose":
            let offered = (object["offered"] as? [Int]) ?? []
            let user = object["hasUsername"] as? Bool ?? false, password = object["hasPassword"] as? Bool ?? false
            if offered.contains(30), user, password { return answer(["type": 30]) }
            if offered.contains(2), password, !user { return answer(["type": 2]) }
            if offered.contains(1) { return answer(["type": 1]) }
            if offered.contains(30) { return answer(["refusal": "credentialsRequired"]) }
            if offered.contains(2) { return answer(["refusal": "passwordRequired"]) }
            return answer(["refusal": "noSupportedSecurityType", "offered": offered])
        case "vnc_security_server_chosen":
            let word = object["word"] as? Int ?? 0
            guard [1, 2, 30].contains(word) else { return answer(["refusal": "noSupportedSecurityType", "offered": [UInt8(truncatingIfNeeded: word)]]) }
            return answer(["type": word])
        case "vnc_password_response":
            let key = Array(((object["password"] as? String) ?? "").utf8.prefix(8)) + [UInt8](repeating: 0, count: 8)
            let response = bytes("challenge").enumerated().map { $0.element ^ key[$0.offset % 8] ^ 0x5A }
            return answer(["response": Data(response).base64EncodedString()])
        case let demo where demo.hasPrefix("vnc_demo_"):
            return answer(FixtureDemoRules.answer(demo, object))
        default:
            return answer(NSNull())
        }
    }
}
