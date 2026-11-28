import CmuxVNC
import Foundation

/// A stand-in for cmux-vnc's demo server ops (`vnc_demo_*`; the real ones and their known
/// answers are tested in Rust, cmux-tui/crates/cmux-vnc/src/demo.rs): just enough RFB 3.8 for the
/// client tests. Its ZRLE tiles are all raw, its cursor a white 1×1 dot, its challenge fixed, and
/// its password check the fixture's `vnc_password_response`.
enum FixtureDemoRules {
    static func answer(_ operation: String, _ object: [String: Any]) -> Any {
        var connection = object["connection"] as? [String: Any] ?? [:]
        let encodings = connection["encodings"] as? [Int] ?? []
        switch operation {
        case "vnc_demo_receive":
            return receive(&connection, input: bytes(object["input"]), config: object["config"] as? [String: Any] ?? [:])
        case "vnc_demo_flush":
            let cursor = encodings.contains(-239) && !(connection["cursorSent"] as? Bool ?? false)
            let damage = object["damagePending"] as? Bool ?? false
            guard connection["phase"] as? String == "normal", connection["requested"] as? Bool ?? false, cursor || damage else {
                return ["connection": connection, "send": false, "head": ""]
            }
            connection["requested"] = false
            if cursor { connection["cursorSent"] = true }
            var head = [0, 0] + be16((object["damageCount"] as? Int ?? 0) + (cursor ? 1 : 0))
            if cursor { head += be16(0) + be16(0) + be16(1) + be16(1) + be32(-239) + [255, 255, 255, 0, 0x80] }
            return ["connection": connection, "send": true, "head": Data(head).base64EncodedString()]
        case "vnc_demo_rect":
            let x = object["x"] as? Int ?? 0, y = object["y"] as? Int ?? 0
            let width = object["width"] as? Int ?? 0, height = object["height"] as? Int ?? 0
            let pixels = bytes(object["pixels"])
            let zrle = encodings.contains(16)
            var payload = pixels
            if zrle {
                payload = []
                for tileY in stride(from: 0, to: height, by: 64) {
                    for tileX in stride(from: 0, to: width, by: 64) {
                        payload.append(0)
                        for row in tileY ..< min(tileY + 64, height) {
                            for col in tileX ..< min(tileX + 64, width) {
                                let offset = (row * width + col) * 4
                                payload += pixels[offset ..< offset + 3]
                            }
                        }
                    }
                }
            }
            let header = be16(x) + be16(y) + be16(width) + be16(height) + be32(zrle ? 16 : 0)
            return ["header": Data(header).base64EncodedString(), "zrle": zrle, "payload": Data(payload).base64EncodedString()]
        default:
            return NSNull()
        }
    }

    private static func receive(_ connection: inout [String: Any], input: [UInt8], config: [String: Any]) -> [String: Any] {
        let password = config["password"] as? String
        var phase = connection["phase"] as? String ?? "version"
        var consumed = 0, reply: [UInt8] = [], events: [[String: Any]] = [], flush = false
        var failure: String?
        read: while failure == nil {
            let rest = Array(input[consumed...])
            switch phase {
            case "version":
                guard rest.count >= 12 else { break read }
                consumed += 12
                reply += [1, password == nil ? 1 : 2]
                phase = "security"
            case "security":
                guard let chosen = rest.first else { break read }
                consumed += 1
                if chosen == 2, password != nil {
                    let challenge = [UInt8](repeating: 7, count: 16)
                    connection["challenge"] = challenge.map(Int.init)
                    reply += challenge
                    phase = "auth"
                } else if chosen == 1, password == nil {
                    reply += [0, 0, 0, 0]
                    phase = "clientInit"
                } else {
                    failure = "unsupported security type"
                }
            case "auth":
                guard rest.count >= 16 else { break read }
                consumed += 16
                let key = Array((password ?? "").utf8.prefix(8)) + [UInt8](repeating: 0, count: 8)
                let challenge = (connection["challenge"] as? [Int] ?? []).map(UInt8.init)
                let expected = challenge.enumerated().map { $0.element ^ key[$0.offset % 8] ^ 0x5A }
                if Array(rest[0 ..< 16]) == expected {
                    reply += [0, 0, 0, 0]
                    phase = "clientInit"
                } else {
                    failure = "Authentication failed"
                }
            case "clientInit":
                guard !rest.isEmpty else { break read }
                consumed += 1
                let name = Array((config["name"] as? String ?? "").utf8)
                reply += be16(config["width"] as? Int ?? 0) + be16(config["height"] as? Int ?? 0) + RFBPixelFormat.bgrx.encoded
                reply += be32(name.count) + name
                phase = "normal"
            default:
                guard let kind = rest.first else { break read }
                func u32(_ at: Int) -> Int { Int(rest[at]) << 24 | Int(rest[at + 1]) << 16 | Int(rest[at + 2]) << 8 | Int(rest[at + 3]) }
                switch kind {
                case 0:
                    guard rest.count >= 20 else { break read }
                    consumed += 20
                case 2:
                    guard rest.count >= 4 else { break read }
                    let count = Int(rest[2]) << 8 | Int(rest[3])
                    guard rest.count >= 4 + count * 4 else { break read }
                    connection["encodings"] = (0 ..< count).map { Int(Int32(truncatingIfNeeded: u32(4 + $0 * 4))) }
                    consumed += 4 + count * 4
                case 3:
                    guard rest.count >= 10 else { break read }
                    if rest[1] == 0 { events.append(["type": "fullUpdate"]) }
                    connection["requested"] = true
                    flush = true
                    consumed += 10
                case 4:
                    guard rest.count >= 8 else { break read }
                    let keysym = u32(4), down = rest[1] != 0
                    if keysym == 0xFFE1 || keysym == 0xFFE2 { connection["shift"] = down }
                    events.append(["type": "key", "keysym": keysym, "down": down, "shift": connection["shift"] as? Bool ?? false])
                    consumed += 8
                case 5:
                    guard rest.count >= 6 else { break read }
                    connection["buttons"] = Int(rest[1])
                    events.append(["type": "pointer", "x": Int(rest[2]) << 8 | Int(rest[3]), "y": Int(rest[4]) << 8 | Int(rest[5]),
                                   "leftDown": rest[1] & 1 != 0])
                    consumed += 6
                case 6:
                    guard rest.count >= 8, rest.count >= 8 + u32(4) else { break read }
                    consumed += 8 + u32(4)
                default:
                    failure = "unknown message \(kind)"
                }
            }
        }
        connection["phase"] = phase
        let failureBytes: Any = failure.map { reason in
            Data(be32(1) + be32(reason.utf8.count) + Array(reason.utf8)).base64EncodedString()
        } ?? NSNull()
        return ["connection": connection, "consumed": consumed, "reply": Data(reply).base64EncodedString(),
                "events": events, "flush": flush, "failure": failureBytes]
    }

    private static func bytes(_ value: Any?) -> [UInt8] {
        (value as? String).flatMap { Data(base64Encoded: $0) }.map(Array.init) ?? []
    }

    private static func be16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }

    private static func be32(_ value: Int) -> [UInt8] {
        let word = UInt32(truncatingIfNeeded: value)
        return [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16),
                UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
    }
}
