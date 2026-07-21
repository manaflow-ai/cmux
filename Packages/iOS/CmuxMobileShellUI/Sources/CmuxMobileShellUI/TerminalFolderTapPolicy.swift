import CmuxAgentChat

/// Decides whether a detected terminal path should open as an artifact.
struct TerminalFolderTapPolicy: Sendable {
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

        let (decisions, continuation) = AsyncStream<Decision>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let statTask = Task { @MainActor in
            let decision: Decision
            do {
                let kind = try await stat(path)
                decision = kind == .directory ? .focusTerminal : .openArtifact
            } catch {
                decision = .focusTerminal
            }
            continuation.yield(decision)
            continuation.finish()
        }
        let deadlineTask = Task {
            do {
                // This bounded, cancellable sleep is the intentional classification deadline.
                try await Task.sleep(for: classificationDeadline)
            } catch {
                return
            }
            continuation.yield(.focusTerminal)
            continuation.finish()
        }

        defer {
            statTask.cancel()
            deadlineTask.cancel()
        }
        var iterator = decisions.makeAsyncIterator()
        return await iterator.next() ?? .focusTerminal
    }
}
