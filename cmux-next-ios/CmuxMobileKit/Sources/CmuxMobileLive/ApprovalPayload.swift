import CmuxMobileAgentChat
import CryptoKit
import Foundation

/// What the phone's approval key signs for one Allow or answer
/// (verify/phone-approvals.md; acpmux `hub/approvers.rs` checks the same
/// bytes): the domain, then each field after one NUL byte.
public struct ApprovalPayload: Sendable, Equatable {
    public static let domain = "acpmux-approver-decision-v1"
    /// How long a signature stays valid; acpmux accepts at most 300 s.
    public static let lifetime: TimeInterval = 120

    public var instance: String
    public var macDevice: String
    public var approver: String
    public var session: String
    public var permission: String
    public var option: String
    public var nonce: String
    /// Unix seconds.
    public var expiresAt: Int
    /// The answers, for a question; nil for a plain allow.
    public var answers: JSONValue?

    public init(instance: String, macDevice: String, approver: String, session: String, permission: String,
                option: String, nonce: String, expiresAt: Int, answers: JSONValue? = nil) {
        self.instance = instance
        self.macDevice = macDevice
        self.approver = approver
        self.session = session
        self.permission = permission
        self.option = option
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.answers = answers
    }

    /// The signed bytes.
    public var message: Data {
        Self.joined(Self.domain, [instance, macDevice, approver, session, permission, option, nonce,
                                  String(expiresAt), Self.answersDigest(answers)])
    }

    /// `_meta.acpmux` of the `permission_respond` that carries `signature`.
    public func meta(signature: Data) -> JSONValue {
        .object(["acpmux": .object([
            "decisionNonce": .string(nonce),
            "approverDecision": .object([
                "approver": .string(approver), "expiresAt": .number(Double(expiresAt)),
                "signature": .string(Self.hex(signature)),
            ]),
        ])])
    }

    /// Lowercase hex SHA-256 of the canonical answers JSON; empty for none.
    public static func answersDigest(_ answers: JSONValue?) -> String {
        guard let answers, answers != .null else { return "" }
        var text = ""
        canonicalJSON(answers, into: &text)
        return hex(Data(SHA256.hash(data: Data(text.utf8))))
    }

    /// JSON with object keys in UTF-8 byte order, no whitespace, and only `"`,
    /// `\` and control characters escaped (acpmux `canonical_json`).
    public static func canonicalJSON(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += canonicalNumber(n)
        case .string(let s): canonicalString(s, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                canonicalJSON(item, into: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (index, key) in object.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }).enumerated() {
                if index > 0 { out += "," }
                canonicalString(key, into: &out)
                out += ":"
                canonicalJSON(object[key] ?? .null, into: &out)
            }
            out += "}"
        }
    }

    /// A number as acpmux prints it (serde_json `Number` display) after reading
    /// the text this phone sends for it (`JSONEncoder`, review m9): an integer
    /// literal stays its digits; any other literal is an f64, printed shortest
    /// round-trip with serde's layout (`100.0`, `0.00001`, `1e-6`, `1.5e+20`).
    public static func canonicalNumber(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        let wire = (try? JSONEncoder().encode(n)).map { String(decoding: $0, as: UTF8.self) } ?? n.description
        if wire == "-0" { return "-0.0" }
        let digits = wire.hasPrefix("-") ? wire.dropFirst() : Substring(wire)
        if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), Int64(wire) != nil || UInt64(wire) != nil {
            return wire
        }
        return floatText(n)
    }

    /// serde_json's f64 text: shortest round-trip digits (Swift's are the same),
    /// laid out as ryu does.
    static func floatText(_ n: Double) -> String {
        let sign = n.sign == .minus ? "-" : ""
        let text = abs(n).description
        let parts = text.split(separator: "e", maxSplits: 1)
        let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].split(separator: ".", maxSplits: 1)
        let fraction = mantissa.count == 2 ? String(mantissa[1]) : ""
        var digits = Array(String(mantissa[0]) + fraction)
        var k = exponent - fraction.count
        while digits.first == "0" { digits.removeFirst() }
        while digits.last == "0" { digits.removeLast(); k += 1 }
        guard !digits.isEmpty else { return sign + "0.0" }
        let length = digits.count
        let kk = length + k
        let d = String(digits)
        func exp(_ e: Int) -> String { e >= 0 ? "e+\(e)" : "e\(e)" }
        if k >= 0, kk <= 16 {
            return sign + d + String(repeating: "0", count: k) + ".0"
        } else if kk > 0, kk <= 16 {
            return sign + String(digits[..<kk]) + "." + String(digits[kk...])
        } else if kk > -5, kk <= 0 {
            return sign + "0." + String(repeating: "0", count: -kk) + d
        } else if length == 1 {
            return sign + d + exp(kk - 1)
        } else {
            return sign + String(digits[0]) + "." + String(digits[1...]) + exp(kk - 1)
        }
    }

    private static func canonicalString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    static func joined(_ domain: String, _ parts: [String]) -> Data {
        var data = Data(domain.utf8)
        for part in parts {
            data.append(0)
            data.append(Data(part.utf8))
        }
        return data
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// What the phone's identity key signs for one link's pairing challenge
/// (cmux-mobile-host `pairing.rs`).
public struct LinkAuthPayload: Sendable, Equatable {
    public static let domain = "cmux-mobile-link-auth-v1"
    public var mac: String
    public var phone: String
    public var nonce: String
    public var identityKey: String
    public var approvalKey: String
    /// `pair` or `unpair`.
    public var action: String

    public init(mac: String, phone: String, nonce: String, identityKey: String, approvalKey: String, action: String) {
        self.mac = mac
        self.phone = phone
        self.nonce = nonce
        self.identityKey = identityKey
        self.approvalKey = approvalKey
        self.action = action
    }

    public var message: Data {
        ApprovalPayload.joined(Self.domain, [mac, phone, nonce, identityKey, approvalKey, action])
    }
}
