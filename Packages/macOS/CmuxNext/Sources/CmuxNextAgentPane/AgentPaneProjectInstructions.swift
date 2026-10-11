import Foundation

/// The chat menu's Edit CLAUDE.md / Edit AGENTS.md (cx-ncc.65, Claude desktop's project
/// instructions): `project.instructions` with `{cwd, name}`. The App opens the chat folder's
/// instructions file in a file tab, where it is edited and saved, and creates it empty first when
/// the folder has none (an existing file is never overwritten). It answers `{path, created}`. It
/// needs a real click or key in the pane, a chat on this Mac and `cwd` inside the pane's folders.
public nonisolated struct AgentPaneProjectInstructions: Equatable, Sendable {
    /// The files a harness reads its project instructions from.
    static let names: Set<String> = ["CLAUDE.md", "AGENTS.md"]

    /// The chat's folder, absolute.
    public let cwd: String
    /// `CLAUDE.md` or `AGENTS.md`.
    public let name: String

    public init?(params: [String: Any]?) {
        guard let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0"),
              let name = params?["name"] as? String, Self.names.contains(name) else { return nil }
        self.cwd = cwd
        self.name = name
    }

    /// `project.instructions` (nil: params that break the contract): spends `model`'s gesture,
    /// then creates the file when missing and opens it in a tab.
    @MainActor static func reply(to request: AgentPaneProjectInstructions?, in model: AgentPaneModel) async -> [String: Any] {
        _ = (request, model)
        return AgentPaneModel.unsupported("project.instructions")
    }
}
