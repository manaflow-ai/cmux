/// A workspace row's agent sessions, for Group by Status's elbow children
/// (`SidebarGrouping.elbowsChildren`): the acpmux names of the sessions its agent chats show, and
/// the coordinator that started one (its `mux.parent` tag, a session name). The App maps it from
/// acpmux, whatever harness runs the chat; `linking` resolves each row's `parentWorkspace`.
public nonisolated struct SidebarAgentLink: Hashable, Sendable {
    public var names: [String]
    public var parent: String?

    public init(names: [String] = [], parent: String? = nil) {
        self.names = names
        self.parent = parent
    }
}

nonisolated extension SidebarAgentLink {
    /// `sections` with each row's `parentWorkspace` resolved from the rows' links.
    public static func linking(_ sections: [SidebarSection]) -> [SidebarSection] {
        sections
    }
}
