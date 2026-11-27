internal import CCmuxAgentPanePolicyFFI
import Foundation

/// The decision proof of a relayed answer to a question (acpmux `decision_answers_proof`,
/// `hub/person/decision_answers.rs`): an AskUserQuestion answered in this pane for a chat on
/// another machine. The allow's proof also covers the answers, and the annotations (Claude Code's
/// chosen preview and notes) when there are any, so that machine's daemon counts the answer as the
/// person's and a relay can neither swap nor add them. Without it every such answer was refused as
/// "accepted only from the cmux app" (Leo, 2026-10-21).
nonisolated extension AcpmuxSecretKey {
    /// `personDecision` of a relayed answer; nil when the answers or annotations have no canonical
    /// form (a fractional number, which no question answer has). The annotations' digest is a
    /// seventh part only when there are annotations, as acpmux reads it.
    public func decisionProof(instance: String, session: String, permission: String, option: String, nonce: String,
                              answers: Any, annotations: Any? = nil) -> String? {
        guard let answersDigest = Self.canonicalDigest(answers) else { return nil }
        var parts = [instance, session, permission, option, nonce, answersDigest]
        if let annotations, !(annotations is NSNull) {
            guard let notesDigest = Self.canonicalDigest(annotations) else { return nil }
            parts.append(notesDigest)
        }
        return mac(domain: "acpmux-person-decision-answers-v1", parts: parts)
    }

    /// The lowercase hex sha256 of `value`'s canonical JSON bytes (acpmux
    /// `approvers::answers_digest`), from the Rust policy (cmux-agent-pane-policy `canonical_digest`).
    /// Hex, so comparing two is comparing those bytes: `String` equality treats canonically
    /// equivalent Unicode (a composed and a decomposed é) as equal.
    static func canonicalDigest(_ value: Any) -> String? {
        AcpmuxCanonicalPolicy.call("canonical_digest", value: value)?["digest"] as? String
    }

    /// The bytes acpmux hashes (`approvers::canonical_json`), from the Rust policy
    /// (cmux-agent-pane-policy `canonical_json`): object keys in UTF-8 byte order, no whitespace,
    /// and only `"`, `\` and control characters escaped. nil for a value with no canonical form
    /// (a fractional number). `value` is what `JSONSerialization` parsed.
    static func canonicalJSON(_ value: Any) -> String? {
        AcpmuxCanonicalPolicy.call("canonical_json", value: value)?["json"] as? String
    }
}

/// The canonical proof operations are Rust-owned. The request encoder is intentionally local and
/// narrower than JSONSerialization: it keeps UInt64 and negative zero intact before serde parses
/// the request, and it fails closed for values outside the JSON-shaped Foundation subset.
private enum AcpmuxCanonicalPolicy {
    private static let maximumValueContainerDepth = 126

    static func call(_ op: String, value: Any) -> [String: Any]? {
        var request: [UInt8] = Array("{\"value\":".utf8)
        guard append(value, to: &request, depth: 0) else { return nil }
        request.append(0x7d)

        var out = CmuxAgentPaneBytes(ptr: nil, len: 0)
        defer { cmux_agent_pane_policy_bytes_free(out) }
        let code = request.withUnsafeBufferPointer { request in
            op.withCString { op in
                cmux_agent_pane_policy_call(nil, op, request.baseAddress, request.count, &out)
            }
        }
        guard code == 0, let bytes = out.ptr, out.len > 0 else { return nil }
        let data = Data(bytes: bytes, count: out.len)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func append(_ value: Any, to out: inout [UInt8], depth: Int) -> Bool {
        if value is NSNull {
            appendRaw("null", to: &out)
            return true
        }
        if let string = value as? String {
            append(string, to: &out)
            return true
        }
        if let number = value as? NSNumber {
            return append(number, to: &out)
        }
        if let array = value as? [Any] {
            return append(array, to: &out, depth: depth)
        }
        if let object = value as? [String: Any] {
            return append(object, to: &out, depth: depth)
        }
        if let array = value as? NSArray {
            return append(Array(array), to: &out, depth: depth)
        }
        if let object = value as? NSDictionary {
            var converted: [String: Any] = [:]
            converted.reserveCapacity(object.count)
            for (key, item) in object {
                guard let key = key as? String else { return false }
                converted[key] = item
            }
            return append(converted, to: &out, depth: depth)
        }
        if let value = value as? Int { appendRaw(String(value), to: &out); return true }
        if let value = value as? Int8 { appendRaw(String(value), to: &out); return true }
        if let value = value as? Int16 { appendRaw(String(value), to: &out); return true }
        if let value = value as? Int32 { appendRaw(String(value), to: &out); return true }
        if let value = value as? Int64 { appendRaw(String(value), to: &out); return true }
        if let value = value as? UInt { appendRaw(String(value), to: &out); return true }
        if let value = value as? UInt8 { appendRaw(String(value), to: &out); return true }
        if let value = value as? UInt16 { appendRaw(String(value), to: &out); return true }
        if let value = value as? UInt32 { appendRaw(String(value), to: &out); return true }
        if let value = value as? UInt64 { appendRaw(String(value), to: &out); return true }
        if let value = value as? Double { return append(value, to: &out) }
        if let value = value as? Float { return append(Double(value), to: &out) }
        return false
    }

    private static func append(_ number: NSNumber, to out: inout [UInt8]) -> Bool {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            appendRaw(number.boolValue ? "true" : "false", to: &out)
            return true
        }
        guard let type = String(cString: number.objCType).first else { return false }
        switch type {
        case "c", "s", "i", "l", "q":
            appendRaw(String(number.int64Value), to: &out)
            return true
        case "C", "S", "I", "L", "Q":
            appendRaw(String(number.uint64Value), to: &out)
            return true
        case "f", "d":
            return append(number.doubleValue, to: &out)
        default:
            return false
        }
    }

    private static func append(_ value: Double, to out: inout [UInt8]) -> Bool {
        guard value.isFinite, value.rounded() == value, abs(value) < 1e15 else { return false }
        if value == 0, value.sign == .minus {
            appendRaw("-0.0", to: &out)
        } else {
            appendRaw(String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value), to: &out)
        }
        return true
    }

    private static func append(_ array: [Any], to out: inout [UInt8], depth: Int) -> Bool {
        guard depth < maximumValueContainerDepth else { return false }
        out.append(0x5b)
        for (index, item) in array.enumerated() {
            if index > 0 { out.append(0x2c) }
            guard append(item, to: &out, depth: depth + 1) else { return false }
        }
        out.append(0x5d)
        return true
    }

    private static func append(_ object: [String: Any], to out: inout [UInt8], depth: Int) -> Bool {
        guard depth < maximumValueContainerDepth else { return false }
        out.append(0x7b)
        let keys = object.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        for (index, key) in keys.enumerated() {
            if index > 0 { out.append(0x2c) }
            append(key, to: &out)
            out.append(0x3a)
            guard let item = object[key], append(item, to: &out, depth: depth + 1) else { return false }
        }
        out.append(0x7d)
        return true
    }

    private static func append(_ string: String, to out: inout [UInt8]) {
        out.append(0x22)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: appendRaw(#"\""#, to: &out)
            case 0x5c: appendRaw(#"\\"#, to: &out)
            case 0x08: appendRaw(#"\b"#, to: &out)
            case 0x0c: appendRaw(#"\f"#, to: &out)
            case 0x0a: appendRaw(#"\n"#, to: &out)
            case 0x0d: appendRaw(#"\r"#, to: &out)
            case 0x09: appendRaw(#"\t"#, to: &out)
            case 0..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                out.append(contentsOf: [0x5c, 0x75, 0x30, 0x30, hex[Int(scalar.value) >> 4], hex[Int(scalar.value) & 0xf]])
            default:
                out.append(contentsOf: String(scalar).utf8)
            }
        }
        out.append(0x22)
    }

    private static func appendRaw(_ string: String, to out: inout [UInt8]) {
        out.append(contentsOf: string.utf8)
    }
}
