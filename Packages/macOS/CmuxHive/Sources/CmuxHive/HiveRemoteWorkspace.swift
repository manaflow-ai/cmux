/// One workspace on a remote Mac, as reported by `workspace.list`.
///
/// Value snapshot for the viewer's workspace list (rows never observe stores).
public struct HiveRemoteWorkspace: Equatable, Sendable, Identifiable {
    /// One terminal within the workspace.
    public struct Terminal: Equatable, Sendable, Identifiable {
        /// Stable terminal (surface) identifier on the host.
        public let id: String
        /// User-facing terminal title.
        public let title: String
        /// Whether the terminal holds focus on the host.
        public let isFocused: Bool

        public init(id: String, title: String, isFocused: Bool) {
            self.id = id
            self.title = title
            self.isFocused = isFocused
        }
    }

    /// Stable workspace identifier on the host.
    public let id: String
    /// User-facing workspace title.
    public let title: String
    /// Whether the host currently has this workspace selected.
    public let isSelected: Bool
    /// The workspace's terminals in host order.
    public let terminals: [Terminal]

    public init(id: String, title: String, isSelected: Bool, terminals: [Terminal]) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.terminals = terminals
    }

    /// The terminal to attach when the workspace is opened: the focused one,
    /// else the first.
    public var defaultTerminal: Terminal? {
        terminals.first(where: \.isFocused) ?? terminals.first
    }
}
