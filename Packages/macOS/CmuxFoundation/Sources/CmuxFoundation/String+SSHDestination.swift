import Foundation

public extension String {
    /// Whether ssh would read this destination as an option rather than a host.
    ///
    /// Argv builders that cannot put `--` ahead of the destination (the
    /// interactive ssh command, which the user may extend) reject these
    /// values at input instead.
    ///
    /// ```swift
    /// "-oProxyCommand=x".isOptionLikeSSHDestination   // true
    /// "alice@host-1".isOptionLikeSSHDestination       // false
    /// ```
    var isOptionLikeSSHDestination: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-")
    }
}
