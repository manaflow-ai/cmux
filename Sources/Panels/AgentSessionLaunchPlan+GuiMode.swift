import Foundation

extension AgentSessionLaunchPlan {
    /// Applies a selected Claude model before starting its one-shot stream.
    func applyingGuiModeModel(_ modelID: String?) -> Self {
        guard provider == .claude,
              let modelID,
              !modelID.isEmpty else {
            return self
        }
        return Self(
            provider: provider,
            executableURL: executableURL,
            arguments: arguments + ["--model", modelID],
            environment: environment
        )
    }
}
