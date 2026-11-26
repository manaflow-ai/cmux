import Foundation

/// Controls restored terminal title admission.
///
/// A terminal rebuilt from a session snapshot may replace its persisted title
/// only after startup titles become trustworthy. When cmux seeded initial PTY
/// input, its normalized title is carried as provenance so internal bootstrap
/// text stays hidden without suppressing titles from the resumed process.
public struct RestoredPanelTitleBoundary: Sendable {
    private var phase: RestoredPanelTitlePhase
    private var pendingTitle: String?

    /// Whether authoritative activity has permanently released this boundary.
    public var isReleased: Bool {
        if case .released = phase { return true }
        return false
    }

    /// Creates a boundary from cmux-owned startup provenance and current shell state.
    ///
    /// - Parameters:
    ///   - internallySeededInput: Exact input inserted into the restored PTY by
    ///     cmux, including any surrounding whitespace or newline.
    ///   - shellState: Latest authoritative shell-activity state for the panel.
    public init(
        internallySeededInput: String?,
        shellState: PanelShellActivityState
    ) {
        let normalizedSeededTitle = internallySeededInput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seededTitle = normalizedSeededTitle?.isEmpty == false
            ? normalizedSeededTitle
            : nil
        if let seededTitle, shellState == .commandRunning {
            phase = .internallySeededBootstrapRunning(expectedTitle: seededTitle)
        } else if let seededTitle, shellState == .promptIdle {
            phase = .awaitingInternallySeededBootstrap(expectedTitle: seededTitle)
        } else if seededTitle == nil, shellState == .commandRunning {
            phase = .released
        } else if seededTitle == nil, shellState == .promptIdle {
            phase = .awaitingUserCommand
        } else {
            phase = .awaitingInitialShellPrompt(internallySeededTitle: seededTitle)
        }
        pendingTitle = nil
    }

    /// Evaluates a normalized raw PTY title against the current restore phase.
    ///
    /// Rejected preexec titles may be buffered until a matching shell-activity
    /// transition proves they came from a real command.
    ///
    /// - Parameter rawTitle: Non-empty title after whitespace normalization.
    /// - Returns: `true` when the ordinary title-ownership pipeline may apply it.
    public mutating func shouldApply(rawTitle: String) -> Bool {
        switch phase {
        case .awaitingInitialShellPrompt:
            // A fresh PTY can publish its generic shell/process name before
            // the first prompt. It is never meaningful post-restore state.
            pendingTitle = nil
            return false
        case .awaitingUserCommand:
            // The title callback and shell-state report use independent
            // ingresses, so retain a preexec title until commandRunning.
            pendingTitle = rawTitle
            return false
        case .awaitingInternallySeededBootstrap(let expectedTitle):
            pendingTitle = rawTitle == expectedTitle ? nil : rawTitle
            return false
        case .internallySeededBootstrapRunning(let expectedTitle):
            // The restore verb execs the resumed agent and can remain the
            // foreground command for hours. Suppress only the title proven to
            // be cmux's exact seeded input; any different title is organic.
            return rawTitle != expectedTitle
        case .released:
            return true
        }
    }

    /// Advances the boundary using an authoritative prompt/preexec report.
    ///
    /// - Parameter shellState: Newly observed shell-activity state. Callers
    ///   discard duplicate reports before invoking this method.
    /// - Returns: A buffered genuine title that became admissible, if any.
    public mutating func observe(shellState: PanelShellActivityState) -> String? {
        switch (phase, shellState) {
        case (.awaitingInitialShellPrompt(let internallySeededTitle), .promptIdle):
            pendingTitle = nil
            if let internallySeededTitle {
                phase = .awaitingInternallySeededBootstrap(
                    expectedTitle: internallySeededTitle
                )
            } else {
                phase = .awaitingUserCommand
            }
        case (.awaitingInitialShellPrompt(let internallySeededTitle), .commandRunning):
            if let internallySeededTitle {
                phase = .internallySeededBootstrapRunning(
                    expectedTitle: internallySeededTitle
                )
            } else {
                // No startup title survived, and commandRunning is the first
                // demonstrable activity for an unseeded shell.
                phase = .released
            }
        case (.awaitingUserCommand, .promptIdle):
            pendingTitle = nil
        case (.awaitingUserCommand, .commandRunning):
            let title = pendingTitle
            pendingTitle = nil
            phase = .released
            return title
        case (.awaitingInternallySeededBootstrap(let expectedTitle), .promptIdle):
            // Initial input is written when the shell becomes ready. This
            // prompt belongs to startup, not to a completed bootstrap.
            pendingTitle = nil
            phase = .awaitingInternallySeededBootstrap(expectedTitle: expectedTitle)
        case (.awaitingInternallySeededBootstrap(let expectedTitle), .commandRunning):
            let title = pendingTitle
            pendingTitle = nil
            phase = .internallySeededBootstrapRunning(expectedTitle: expectedTitle)
            return title
        case (.internallySeededBootstrapRunning, .promptIdle):
            // The internal command has exited. Preserve its last genuine title
            // until the next user command establishes new ownership.
            phase = .awaitingUserCommand
            pendingTitle = nil
        case (_, .unknown),
             (.internallySeededBootstrapRunning, .commandRunning):
            break
        case (.released, .promptIdle),
             (.released, .commandRunning):
            break
        }
        return nil
    }
}
