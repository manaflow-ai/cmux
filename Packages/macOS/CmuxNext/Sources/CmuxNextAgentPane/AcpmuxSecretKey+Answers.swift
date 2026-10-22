import CommonCrypto
import Foundation

/// The decision proof of a relayed answer to a question (acpmux `decision_answers_proof`,
/// `hub/person/decision_answers.rs`): an AskUserQuestion answered in this pane for a chat on
/// another machine. The allow's proof also covers the answers, so that machine's daemon counts
/// the answer as the person's and a relay cannot swap them. Without it every such answer was
/// refused as "accepted only from the cmux app" (Leo, 2026-10-21).
extension AcpmuxSecretKey {
    /// `personDecision` of a relayed answer; nil when the answers have no canonical form (a
    /// fractional number, which no question answer has).
    public func decisionProof(instance: String, session: String, permission: String, option: String, nonce: String,
                              answers: Any) -> String? {
        guard let canonical = Self.canonicalJSON(answers) else { return nil }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let text = Array(canonical.utf8)
        text.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(text.count), &digest) }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return mac(domain: "acpmux-person-decision-answers-v1", parts: [instance, session, permission, option, nonce, hex])
    }

    /// The bytes acpmux hashes (`approvers::canonical_json`): object keys in UTF-8 byte order, no
    /// whitespace, and only `"`, `\` and control characters escaped (`\b \f \n \r \t`, else
    /// `\u00xx`). `value` is what `JSONSerialization` parsed.
    static func canonicalJSON(_ value: Any) -> String? {
        switch value {
        case is NSNull:
            return "null"
        case let string as String:
            return canonicalString(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                guard double.rounded() == double, abs(double) < 1e15 else { return nil }
                return String(Int64(double))
            }
            return number.stringValue
        case let array as [Any]:
            var parts: [String] = []
            for item in array {
                guard let part = canonicalJSON(item) else { return nil }
                parts.append(part)
            }
            return "[" + parts.joined(separator: ",") + "]"
        case let object as [String: Any]:
            var parts: [String] = []
            for key in object.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                guard let item = object[key], let part = canonicalJSON(item) else { return nil }
                parts.append(canonicalString(key) + ":" + part)
            }
            return "{" + parts.joined(separator: ",") + "}"
        default:
            return nil
        }
    }

    private static func canonicalString(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
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
        return out + "\""
    }
}
