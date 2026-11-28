internal import CmuxNextHomeModel

/// Runs the Rust dock op `op` (`dock.*`, cmux-home-rules) on `input`; a failed call is a bug
/// (asserted in debug) and answers `fallback`, the most conservative reply.
nonisolated func dockRule<In: Encodable, Out: Decodable>(_ op: String, _ input: In, fallback: @autoclosure () -> Out) -> Out {
    do { return try HomeRules.call(op, input) } catch { assertionFailure("\(error)"); return fallback() }
}

/// A tagged wire value (`{"type": …}`) as the dock ops write their enums.
nonisolated struct DockTagged: Decodable {
    var type: String
    var conversation: String?
}
