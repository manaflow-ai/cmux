import Foundation

/// The resolved outcome of classifying the `surface_id` / `terminal_id` /
/// `tab_id` terminal-alias triple carried by a mobile v2 RPC request.
///
/// The three keys are aliases for the same target terminal: a request may carry
/// any one of them (or several, as long as they agree). ``classify(_:)`` reduces
/// an ordered set of per-key ``Read``s into a single outcome:
///
/// - ``missing``: no alias key was present.
/// - ``value(_:)``: one UUID resolved (all present keys agreed on it).
/// - ``invalid``: a present key was non-null but did not parse as a UUID.
/// - ``conflict``: two present keys parsed to different UUIDs.
public enum MobileTerminalAliasUUID: Sendable, Equatable {
    case missing
    case value(UUID)
    case invalid
    case conflict

    /// A single alias-id read taken from the request params: whether the key was
    /// present and non-null, plus a *lazy* resolver for the UUID it parses to.
    ///
    /// The app-side caller performs the `[String: Any]` extraction (the v2 wire
    /// `hasNonNullParam` presence check) eagerly, but defers UUID parsing into
    /// ``resolveUUID`` so ``classify(_:)`` can invoke it in the same order, and
    /// only as far as, the original loop did. This matters because the app's
    /// real resolver is not a pure dict read: a present, non-UUID-string value
    /// triggers a synchronous main-actor hop and a control-handle lookup. Eagerly
    /// resolving every present key would perform those side effects for trailing
    /// keys that the original short-circuiting loop never evaluated, so the read
    /// keeps the parse lazy to preserve the observable side-effect sequence.
    public struct Read {
        /// Whether the key was present and non-null in the request params.
        public let present: Bool
        /// Lazily parses the present key's value into a UUID, returning `nil` when
        /// it fails to parse. Invoked by ``classify(_:)`` at most once, and only
        /// for a present key reached before a short-circuit.
        public let resolveUUID: () -> UUID?

        /// Creates an alias read pairing a presence flag with a lazy UUID parse.
        public init(present: Bool, resolveUUID: @escaping () -> UUID?) {
            self.present = present
            self.resolveUUID = resolveUUID
        }
    }

    /// Classifies an ordered set of alias-id reads (in `surface_id`,
    /// `terminal_id`, `tab_id` order) into a single terminal-alias outcome.
    ///
    /// A present read whose ``Read/resolveUUID`` returns `nil` short-circuits to
    /// ``invalid``; two present reads that resolve to differing UUIDs
    /// short-circuit to ``conflict``; agreeing present reads collapse to
    /// ``value(_:)``; no present reads is ``missing``. ``Read/resolveUUID`` is
    /// evaluated lazily and in order, and not at all for reads after a
    /// short-circuit, matching the original loop's side-effect sequence.
    public static func classify(_ reads: [Read]) -> MobileTerminalAliasUUID {
        var selected: UUID?
        var sawAlias = false
        for read in reads {
            guard read.present else {
                continue
            }
            sawAlias = true
            guard let candidate = read.resolveUUID() else {
                return .invalid
            }
            if let selected, selected != candidate {
                return .conflict
            }
            selected = selected ?? candidate
        }
        if let selected {
            return .value(selected)
        }
        return sawAlias ? .invalid : .missing
    }
}
