import Foundation

struct RepositorySetupPrompt: Identifiable, Equatable {
    var id: UUID { workspaceID }
    let workspaceID: UUID
    let resolution: RepositoryScriptResolution
}
