/// The four directional Ghostty `goto_split` shortcuts cmux mirrors into its own
/// pane-focus navigation, decoded from a Ghostty config into the package's
/// Sendable ``GhosttyTriggerShortcut`` value.
///
/// This replaces the four parallel stored optionals
/// (`ghosttyGotoSplit{Left,Right,Up,Down}Shortcut`) that AppDelegate used to hold
/// and the `refreshGhosttyGotoSplitShortcuts()` builder that populated them from
/// the live `ghostty_config_trigger` lookups. Holding them as one value keyed by
/// ``Direction`` removes the four-way duplication: the GhosttyKit boundary lift
/// (reading the C config and decoding each trigger) lives once in
/// ``GhosttyGotoSplitShortcuts/init(decodingConfig:)`` (see
/// `GhosttyGotoSplitShortcuts+GhosttyKit.swift`), and the app target reads each
/// direction's decoded ``GhosttyTriggerShortcut`` through ``shortcut(for:)`` to
/// build its `StoredShortcut` and run the `NSEvent` matching.
///
/// The value stores the package-visible ``GhosttyTriggerShortcut`` per direction,
/// not the app's `StoredShortcut` (a CmuxSettings type the package cannot see):
/// the app maps each direction's decoded shortcut onto its own `StoredShortcut`
/// at the call seam, exactly as the old `storedShortcutFromGhosttyTrigger` did.
public struct GhosttyGotoSplitShortcuts: Sendable, Equatable, Hashable {
    /// A pane-focus direction Ghostty binds a `goto_split` action to.
    public enum Direction: String, Sendable, Equatable, Hashable, CaseIterable {
        /// `goto_split:left`.
        case left
        /// `goto_split:right`.
        case right
        /// `goto_split:up`.
        case up
        /// `goto_split:down`.
        case down

        /// The Ghostty config action key (`goto_split:<direction>`) whose trigger
        /// binding this direction reads, used by the GhosttyKit-boundary builder.
        public var ghosttyActionKey: String {
            "goto_split:\(rawValue)"
        }
    }

    /// The decoded `goto_split:left` shortcut, or `nil` when the binding is unset
    /// or maps to a key/trigger cmux does not render.
    public var left: GhosttyTriggerShortcut?
    /// The decoded `goto_split:right` shortcut, or `nil`.
    public var right: GhosttyTriggerShortcut?
    /// The decoded `goto_split:up` shortcut, or `nil`.
    public var up: GhosttyTriggerShortcut?
    /// The decoded `goto_split:down` shortcut, or `nil`.
    public var down: GhosttyTriggerShortcut?

    /// An empty set with every direction unset, the state cmux uses when Ghostty
    /// has no resolved config (the old builder's `config == nil` branch).
    public static let none = GhosttyGotoSplitShortcuts()

    /// Creates a set from per-direction decoded shortcuts.
    /// - Parameters:
    ///   - left: The decoded `goto_split:left` shortcut, or `nil`.
    ///   - right: The decoded `goto_split:right` shortcut, or `nil`.
    ///   - up: The decoded `goto_split:up` shortcut, or `nil`.
    ///   - down: The decoded `goto_split:down` shortcut, or `nil`.
    public init(
        left: GhosttyTriggerShortcut? = nil,
        right: GhosttyTriggerShortcut? = nil,
        up: GhosttyTriggerShortcut? = nil,
        down: GhosttyTriggerShortcut? = nil
    ) {
        self.left = left
        self.right = right
        self.up = up
        self.down = down
    }

    /// The decoded shortcut for a direction, or `nil` when that binding is unset.
    /// - Parameter direction: The pane-focus direction to read.
    /// - Returns: The decoded ``GhosttyTriggerShortcut``, or `nil`.
    public func shortcut(for direction: Direction) -> GhosttyTriggerShortcut? {
        switch direction {
        case .left: left
        case .right: right
        case .up: up
        case .down: down
        }
    }
}
