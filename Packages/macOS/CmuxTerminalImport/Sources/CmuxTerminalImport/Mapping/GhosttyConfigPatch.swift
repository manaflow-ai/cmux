/// The result of applying imported settings to a Ghostty config body.
public struct GhosttyConfigPatch: Equatable, Sendable {
    /// One key's before and after.
    public struct Change: Equatable, Sendable {
        /// The Ghostty config key.
        public var key: String
        /// Every value the config assigned to the key before, in file order (empty when absent).
        public var oldValues: [String]
        /// The value written now.
        public var newValue: String

        /// Whether the config already had exactly this value.
        public var isUnchanged: Bool { oldValues == [newValue] }

        /// Creates a change record.
        public init(key: String, oldValues: [String], newValue: String) {
            self.key = key
            self.oldValues = oldValues
            self.newValue = newValue
        }
    }

    /// The config body after the patch.
    public var contents: String
    /// One entry per written key, in the order the settings were given.
    public var changes: [Change]

    /// Creates a patch result.
    public init(contents: String, changes: [Change]) {
        self.contents = contents
        self.changes = changes
    }

    /// Whether the patch changes the file.
    public var hasChanges: Bool { changes.contains { !$0.isUnchanged } }

    /// A unified-diff style listing (`-` old, `+` new) of every key the patch writes.
    public var diffLines: [String] {
        changes.flatMap { change -> [String] in
            if change.isUnchanged {
                return ["  \(change.key) = \(change.newValue)"]
            }
            return change.oldValues.map { "- \(change.key) = \($0)" } + ["+ \(change.key) = \(change.newValue)"]
        }
    }
}
