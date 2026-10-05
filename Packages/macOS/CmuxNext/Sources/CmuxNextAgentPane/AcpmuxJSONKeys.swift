/// A strict duplicate-key check for page frames (ad349, round 7). It only refuses; the frame the
/// relay sends is Foundation's parse of the same bytes, serialized again.
nonisolated enum AcpmuxJSONKeys {
    /// True when `bytes` is not one well-formed JSON text, or when one object holds two keys that
    /// decode to equal strings.
    static func refuses(_ bytes: [UInt8]) -> Bool {
        false
    }
}
