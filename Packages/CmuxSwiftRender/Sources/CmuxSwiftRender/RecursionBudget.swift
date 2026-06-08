/// A shared recursion-depth counter that bounds interpreter nesting so
/// pathological or malicious authored source degrades to a truncated render
/// instead of overflowing the stack and crashing the host.
///
/// One instance is created at the root ``Environment`` and shared with every
/// child scope. Recursive evaluation entry points call ``enter()`` on the way
/// in (always paired with ``leave()`` via `defer`) and bail when ``exceeded``.
final class RecursionBudget {
    private(set) var depth = 0
    private let limit: Int

    /// - Parameter limit: Maximum interpreter nesting depth. The default (400)
    ///   is far beyond any legitimate sidebar yet well under the native stack
    ///   limit, so deep-but-finite trees still render while infinite recursion
    ///   is cut off.
    init(limit: Int = 400) {
        self.limit = limit
    }

    /// Records entry into one more nesting level.
    func enter() {
        depth += 1
    }

    /// Records exit from a nesting level.
    func leave() {
        if depth > 0 { depth -= 1 }
    }

    /// Whether nesting has passed the limit; callers should bail when true.
    var exceeded: Bool {
        depth > limit
    }
}
