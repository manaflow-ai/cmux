import CmuxAgentChat

/// Decides whether a detected terminal path should open as an artifact.
struct TerminalFolderTapPolicy: Sendable {
    /// Whether detected directory paths should open in the artifact viewer.
    let folderTapEnabled: Bool

    /// Bounds classification so taps never wait on the full RPC deadline for focus.
    let classificationDeadline: Duration = .seconds(2)

    /// The action the terminal tap handler should take for a detected path.
    enum Decision: Sendable, Equatable {
        case openArtifact
        case focusTerminal
    }

    /// Applies the folder-tap preference without adding a stat call while enabled.
    ///
    /// When stat fails, this policy focuses the terminal because the viewer could
    /// not load an unverified artifact either, and a user who disabled folder taps
    /// asked not to be interrupted by a viewer transition.
    func decision(
        for path: String,
        stat: @MainActor @Sendable (String) async throws -> ChatArtifactKind
    ) async -> Decision {
        guard !folderTapEnabled else { return .openArtifact }

        do {
            return try await stat(path) == .directory ? .focusTerminal : .openArtifact
        } catch {
            return .focusTerminal
        }
    }
}
