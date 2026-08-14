import Foundation

/// One action exposed by a prefix-key chord table.
///
/// The action identifier is deliberately a string rather than ``ShortcutAction``.
/// Built-in actions use their stable raw value, while configured and future
/// plugin actions can participate without changing this package's enum.
public struct ShortcutPrefixChordBinding: Sendable, Equatable, Hashable, Identifiable {
    /// Stable action identifier dispatched by the host.
    public let actionID: String
    /// The shared prefix stroke that selects this binding.
    public let firstStroke: ShortcutStroke
    /// The suffix stroke pressed after the prefix.
    public let secondStroke: ShortcutStroke
    /// Human-readable action label used by HUDs and accessibility surfaces.
    public let label: String
    /// Whether the suffix represents the numbered `1...9` action family.
    ///
    /// Numbered actions persist `1` as a placeholder and match the other
    /// digits at runtime. Keeping that invariant on the binding lets the
    /// router advertise and match the family without expanding it into nine
    /// ambiguous entries.
    public let matchesNumberedDigits: Bool
    /// Whether this binding already has priority in cmux's contextual shortcut
    /// routing. A priority binding may win an overlap with one non-priority
    /// binding, while two bindings at the same priority still fail closed.
    public let hasPriorityRouting: Bool

    /// The binding's stable identity, derived from its action identifier.
    public var id: String { actionID }

    /// Creates a prefix/suffix binding.
    ///
    /// - Parameters:
    ///   - actionID: Stable action identifier to return when the suffix matches.
    ///   - firstStroke: Prefix stroke. It is canonicalized before storage.
    ///   - secondStroke: Suffix stroke pressed after the prefix.
    ///   - label: Optional display label; defaults to the action identifier.
    ///   - matchesNumberedDigits: Whether a suffix digit represents the 1...9 family.
    ///   - hasPriorityRouting: Whether contextual routing gives this action priority.
    public init(
        actionID: String,
        firstStroke: ShortcutStroke,
        secondStroke: ShortcutStroke,
        label: String? = nil,
        matchesNumberedDigits: Bool = false,
        hasPriorityRouting: Bool = false
    ) {
        self.actionID = actionID
        self.firstStroke = firstStroke.canonicalized()
        self.secondStroke = secondStroke.canonicalized()
        self.label = label ?? actionID
        self.matchesNumberedDigits = matchesNumberedDigits
        self.hasPriorityRouting = hasPriorityRouting
    }

    /// Convenience initializer for an existing two-stroke persisted binding.
    ///
    /// - Parameters:
    ///   - actionID: Stable action identifier to return when the suffix matches.
    ///   - shortcut: Persisted binding whose second stroke is the suffix.
    ///   - label: Optional display label; defaults to the action identifier.
    ///   - matchesNumberedDigits: Whether a suffix digit represents the 1...9 family.
    ///   - hasPriorityRouting: Whether contextual routing gives this action priority.
    /// - Returns: nil when the persisted value is not a two-stroke binding.
    public init?(
        actionID: String,
        shortcut: StoredShortcut,
        label: String? = nil,
        matchesNumberedDigits: Bool = false,
        hasPriorityRouting: Bool = false
    ) {
        guard let secondStroke = shortcut.second else { return nil }
        self.init(
            actionID: actionID,
            firstStroke: shortcut.first,
            secondStroke: secondStroke,
            label: label,
            matchesNumberedDigits: matchesNumberedDigits,
            hasPriorityRouting: hasPriorityRouting
        )
    }
}
