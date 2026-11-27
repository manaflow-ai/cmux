/// Runs the Rust welcome op `op` (`welcome.*`, cmux-home-rules) on `input`; a failed call is a bug
/// (asserted in debug) and answers `fallback`, the most conservative reply.
nonisolated func welcomeRule<In: Encodable, Out: Decodable>(_ op: String, _ input: In, fallback: @autoclosure () -> Out) -> Out {
    do { return try HomeRules.call(op, input) } catch { assertionFailure("\(error)"); return fallback() }
}
