import SwiftUI

private struct AgentRecentFilesModelEnvironmentKey: EnvironmentKey {
    static let defaultValue: AgentRecentFilesModel? = nil
}

extension EnvironmentValues {
    var agentRecentFilesModel: AgentRecentFilesModel? {
        get { self[AgentRecentFilesModelEnvironmentKey.self] }
        set { self[AgentRecentFilesModelEnvironmentKey.self] = newValue }
    }
}
