import CmuxAgentChat

/// Decides whether a detected terminal path should open as an artifact.
struct TerminalFolderTapPolicy: Sendable {
    private struct ClassificationDeadlineExceeded: Error {}

    /// Whether detected directory paths should open in the artifact viewer.
    let folderTapEnabled: Bool

    /// Bounds classification so taps never wait on the full RPC deadline for focus.
    let classificationDeadline: Duration

    /// Creates a folder-tap policy with a bounded classification deadline.
    init(
        folderTapEnabled: Bool,
        classificationDeadline: Duration = .seconds(2)
    ) {
        self.folderTapEnabled = folderTapEnabled
        self.classificationDeadline = classificationDeadline
    }

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
        stat: @escaping @MainActor @Sendable (String) async throws -> ChatArtifactKind
    ) async -> Decision {
        guard !folderTapEnabled else { return .openArtifact }

        do {
            let kind = try await withThrowingTaskGroup(of: ChatArtifactKind.self) { group in
                group.addTask {
                    try await stat(path)
                }
                group.addTask {
                    // This bounded, cancellable sleep is the intentional classification deadline.
                    try await Task.sleep(for: classificationDeadline)
                    throw ClassificationDeadlineExceeded()
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                return first
            }
            return kind == .directory ? .focusTerminal : .openArtifact
        } catch {
            return .focusTerminal
        }
    }
}
