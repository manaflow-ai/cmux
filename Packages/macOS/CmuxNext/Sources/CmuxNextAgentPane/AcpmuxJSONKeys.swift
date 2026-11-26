import CCmuxAgentPanePolicyFFI

/// A strict duplicate-key check for page frames (ad349, round 7). It only refuses: the frame the
/// relay sends is Foundation's parse of the same bytes, serialized again. Foundation keeps one of
/// two duplicate keys without an error, and the daemon's serde_json keeps the last, so a frame with
/// a duplicate could be checked as one value and acted on as the other.
///
/// The check is cmux-agent-pane-policy's `json_keys.rs` (whole RFC 8259 grammar, no recursion,
/// NFC-equal keys count as one), called in place through `cmux_agent_pane_policy_json_keys_verdict`.
nonisolated enum AcpmuxJSONKeys {
    /// True when `bytes` is not one well-formed JSON text, or when one object holds two keys that
    /// decode to equal strings.
    static func refuses(_ bytes: [UInt8]) -> Bool { verdict(bytes) != .clean }

    nonisolated enum Verdict: Equatable { case clean, malformed, duplicate }

    static func verdict(_ bytes: [UInt8]) -> Verdict {
        bytes.withUnsafeBufferPointer { verdict($0) }
    }

    /// The page frame's own UTF-8, read in place.
    static func verdict(_ text: String) -> Verdict {
        var text = text
        return text.withUTF8 { verdict($0) }
    }

    static func verdict(_ buffer: UnsafeBufferPointer<UInt8>) -> Verdict {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return .malformed }
        switch cmux_agent_pane_policy_json_keys_verdict(base, buffer.count) {
        case 0: return .clean
        case 2: return .duplicate
        default: return .malformed
        }
    }
}
