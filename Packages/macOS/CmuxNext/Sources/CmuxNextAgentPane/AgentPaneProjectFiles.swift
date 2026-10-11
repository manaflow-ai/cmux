import Foundation

/// The chat menu's Add Files to Project (cx-ncc.67, Claude desktop's project knowledge).
enum AgentPaneProjectFiles {
    /// The chat menu's project requests: Edit CLAUDE.md and Add Files to Project.
    @MainActor static func respond(to request: AgentPaneRequest, in model: AgentPaneModel) async -> [String: Any] {
        switch request {
        case .projectInstructions(let instructions): return await AgentPaneProjectInstructions.reply(to: instructions, in: model)
        case .projectAddFiles(let files): return await reply(to: files, in: model)
        default: return AgentPaneModel.unsupported(String(describing: request))
        }
    }

    @MainActor static func reply(to request: AgentPaneProjectInstructions?, in model: AgentPaneModel) async -> [String: Any] {
        AgentPaneModel.unsupported("project.addFiles")
    }
}
