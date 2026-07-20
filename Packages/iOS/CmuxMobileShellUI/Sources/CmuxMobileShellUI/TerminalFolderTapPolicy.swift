import CmuxAgentChat

/// Decides whether a detected terminal path should open as an artifact.
struct TerminalFolderTapPolicy: Sendable {
    /// The action the terminal tap handler should take for a detected path.
    enum Decision: Sendable, Equatable {
        case openArtifact
        case focusTerminal
    }

    /// Applies the folder-tap preference without adding a stat call while enabled.
    static func decision(
        for path: String,
        folderTapEnabled: Bool,
        stat: @MainActor @Sendable (String) async throws -> ChatArtifactKind
    ) async -> Decision {
        guard !folderTapEnabled else { return .openArtifact }

        do {
            return try await stat(path) == .directory ? .focusTerminal : .openArtifact
        } catch {
            return .openArtifact
        }
    }
}
