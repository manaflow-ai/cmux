import CmuxAgentChat

/// Decides whether a detected terminal path should open as an artifact.
struct TerminalFolderTapPolicy: Sendable {
    /// Whether detected directory paths should open in the artifact viewer.
    let folderTapEnabled: Bool

    /// Bounds classification so taps never wait on the full RPC deadline for focus.
    let classificationDeadline: Duration

    /// Clock backing the classification deadline, injected so tests control time.
    let clock: any Clock<Duration>

    /// Creates a folder-tap policy with a bounded classification deadline.
    init(
        folderTapEnabled: Bool,
        classificationDeadline: Duration = .seconds(2),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.folderTapEnabled = folderTapEnabled
        self.classificationDeadline = classificationDeadline
        self.clock = clock
    }

    /// The action the terminal tap handler should take for a detected path.
    enum Decision: Sendable, Equatable {
        case openArtifact
        case focusTerminal
    }

    /// Applies the folder-tap preference without adding a stat call while enabled.
    ///
    /// A terminal-scope authorization refusal defers to the artifact viewer's richer
    /// chat-session authorization. Other stat failures focus the terminal because
    /// infrastructure failures also prevent the viewer from loading the artifact.
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
            } catch ChatArtifactError.forbidden {
                // Terminal-scope authorization not recognizing the path does not make it a
                // folder; the viewer applies richer chat-session authorization and error UI.
                decision = .openArtifact
            } catch {
                decision = .focusTerminal
            }
            continuation.yield(decision)
            continuation.finish()
        }
        let deadlineTask = Task { [clock] in
            do {
                // This bounded, cancellable clock sleep is the intentional
                // classification deadline (injected clock per timing policy).
                try await clock.sleep(for: classificationDeadline, tolerance: nil)
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
