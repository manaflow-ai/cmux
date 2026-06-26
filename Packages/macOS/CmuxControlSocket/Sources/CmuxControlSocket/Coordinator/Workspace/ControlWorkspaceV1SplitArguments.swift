import Foundation

/// The byte-faithful tokenizing of the v1 `new_split` argument remainder
/// (`<direction> [panel]`), split out of the app-resident
/// ``ControlWorkspaceContext/controlNewSplitV1(args:)`` witness so the pure
/// string parsing has a tested, `Sendable` home while the live-state split
/// creation stays app-side.
///
/// The v1 line protocol passes the direction and an optional panel selector as
/// space-separated positional tokens. This value carries only the raw tokens:
/// resolving the direction token into a `SplitDirection` (and emitting the
/// shared `"ERROR: Invalid direction. Use left, right, up, or down."` reply for
/// both the empty and the unknown-token cases) stays on the app side where
/// `SplitDirection` already lives, so this type introduces no new package edge.
public enum ControlWorkspaceV1SplitArguments: Sendable, Equatable {
    /// No direction token was present after trimming (the legacy empty-`parts`
    /// branch). The app emits the invalid-direction reply.
    case empty

    /// A direction token plus the panel remainder. `panel` is the empty string
    /// when no second token was supplied (the legacy `parts.count > 1` ternary),
    /// which the app treats as "use the focused panel".
    case tokens(direction: String, panel: String)

    /// Tokenizes a raw v1 `new_split` argument remainder, reproducing the legacy
    /// `trimmingCharacters` + `split(separator: " ", maxSplits: 1)` behavior
    /// exactly.
    ///
    /// - Parameter rawArguments: The raw argument remainder of the command line.
    public init(rawArguments: String) {
        let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let direction = parts.first else {
            self = .empty
            return
        }
        self = .tokens(direction: direction, panel: parts.count > 1 ? parts[1] : "")
    }
}
