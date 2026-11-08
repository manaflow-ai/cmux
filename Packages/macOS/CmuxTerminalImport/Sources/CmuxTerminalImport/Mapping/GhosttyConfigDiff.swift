/// What importing settings changes in a Ghostty config, key by key.
///
/// The CLI prints ``diffLines`` before writing; the write itself goes through
/// cmux's shared config writer.
public struct GhosttyConfigDiff: Equatable, Sendable {
    /// One key's before and after.
    public struct Change: Equatable, Sendable {
        /// The Ghostty config key.
        public var key: String
        /// Every value the config assigned to the key before, in file order (empty when absent).
        public var oldValues: [String]
        /// The values written now, one line each.
        public var newValues: [String]

        /// Whether the config already had exactly these lines.
        public var isUnchanged: Bool { oldValues == newValues }

        /// Creates a change record.
        public init(key: String, oldValues: [String], newValues: [String]) {
            self.key = key
            self.oldValues = oldValues
            self.newValues = newValues
        }
    }

    /// One entry per written key, in the order the settings were given.
    public var changes: [Change]

    /// Creates a diff.
    public init(changes: [Change]) {
        self.changes = changes
    }

    /// Whether writing the settings would change the file.
    public var hasChanges: Bool { changes.contains { !$0.isUnchanged } }

    /// A unified-diff style listing (`-` old, `+` new) of every key written.
    public var diffLines: [String] {
        changes.flatMap { change -> [String] in
            if change.isUnchanged {
                return change.newValues.map { "  \(change.key) = \($0)" }
            }
            return change.oldValues.map { "- \(change.key) = \($0)" }
                + change.newValues.map { "+ \(change.key) = \($0)" }
        }
    }
}
