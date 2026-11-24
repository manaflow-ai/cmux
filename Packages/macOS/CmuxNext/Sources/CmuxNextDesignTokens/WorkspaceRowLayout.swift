/// A row layout normalized by the Rust `sidebar_row_layout` reducer. Swift
/// renders these tokens; it does not validate or choose between config keys.
public nonisolated struct WorkspaceRowLayout: Hashable, Sendable, Decodable {
    public var custom: Bool
    public var lines: [[String]]
    public var slots: Slots

    public nonisolated struct Slots: Hashable, Sendable, Decodable {
        public var icon: Bool
        public var working: Bool
        public var progress: Bool
    }
}

/// Settings-time snapshots, one per configured (kind, agent) pair. The table
/// never grows while rows are drawn, selected, or updated.
public nonisolated struct WorkspaceRowLayouts: Hashable, Sendable {
    public nonisolated struct Kind: Hashable, Sendable {
        public var fallback: WorkspaceRowLayout?
        public var agents: [String: WorkspaceRowLayout]

        public init(fallback: WorkspaceRowLayout? = nil, agents: [String: WorkspaceRowLayout] = [:]) {
            self.fallback = fallback
            self.agents = agents
        }
    }

    public var kinds: [WorkspaceRowKind: Kind]
    /// Facts needed by any custom row, computed once with the table.
    public var elements: Set<WorkspaceRowElement>

    public init(kinds: [WorkspaceRowKind: Kind] = [:], elements: Set<WorkspaceRowElement> = []) {
        self.kinds = kinds
        self.elements = elements
    }

    public func layout(for kind: WorkspaceRowKind, agent: String?) -> WorkspaceRowLayout? {
        guard let entry = kinds[kind] else { return nil }
        let layout = agent.flatMap { entry.agents[$0] } ?? entry.fallback
        return layout?.custom == true ? layout : nil
    }
}
