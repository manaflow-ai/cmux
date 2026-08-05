import CmuxWorkspaces
import Foundation

extension Workspace {
    /// The transient title-admission boundary for a terminal rebuilt from a
    /// session snapshot. Raw Ghostty titles are untrusted until shell activity
    /// distinguishes startup noise from a real command. Internally seeded
    /// input carries its exact title so that cmux-owned bootstrap text never
    /// becomes user-visible, regardless of the restored agent kind.
    struct RestoredPanelTitleBoundary {
        enum Phase {
            case awaitingInitialShellPrompt(internallySeededTitle: String?)
            case awaitingUserCommand
            case awaitingInternallySeededBootstrap(expectedTitle: String)
            case internallySeededBootstrapRunning(expectedTitle: String)
        }

        var phase: Phase
        var pendingTitle: String?

        init(internallySeededInput: String?, shellState: PanelShellActivityState) {
            let normalizedSeededTitle = internallySeededInput?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let seededTitle = normalizedSeededTitle?.isEmpty == false
                ? normalizedSeededTitle
                : nil
            if let seededTitle, shellState == .commandRunning {
                phase = .internallySeededBootstrapRunning(expectedTitle: seededTitle)
            } else if let seededTitle, shellState == .promptIdle {
                phase = .awaitingInternallySeededBootstrap(expectedTitle: seededTitle)
            } else if seededTitle == nil, shellState == .promptIdle {
                phase = .awaitingUserCommand
            } else {
                phase = .awaitingInitialShellPrompt(internallySeededTitle: seededTitle)
            }
            pendingTitle = nil
        }

        mutating func shouldApply(rawTitle: String) -> Bool {
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
                // Keep the actual cmux-seeded input inert for the lifetime of
                // the bootstrap command. Any other title is organic activity
                // and remains eligible for the normal ownership pipeline.
                return rawTitle != expectedTitle
            }
        }

        mutating func observe(shellState: PanelShellActivityState) -> String? {
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
                    // No startup title survived, and commandRunning is the
                    // first demonstrable activity for an unseeded shell.
                    phase = .awaitingUserCommand
                }
            case (.awaitingUserCommand, .promptIdle):
                pendingTitle = nil
            case (.awaitingUserCommand, .commandRunning):
                return pendingTitle
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
                // The internal command has exited. Preserve its last genuine
                // title until the next user command establishes new ownership.
                phase = .awaitingUserCommand
                pendingTitle = nil
            case (_, .unknown),
                 (.internallySeededBootstrapRunning, .commandRunning):
                break
            }
            return nil
        }
    }

    /// Starts title admission for a newly rebuilt terminal after persisted metadata lands.
    func armRestoredPanelTitleBoundary(panelId: UUID, internallySeededInput: String?) {
        restoredPanelTitleBoundariesByPanelId[panelId] = RestoredPanelTitleBoundary(
            internallySeededInput: internallySeededInput,
            shellState: panelShellActivityStates[panelId] ?? .unknown
        )
    }

    /// Returns whether a raw PTY title has crossed the restored-title boundary.
    func shouldApplyRestoredPanelTitle(panelId: UUID, rawTitle: String) -> Bool {
        guard var boundary = restoredPanelTitleBoundariesByPanelId[panelId] else {
            return true
        }
        let shouldApply = boundary.shouldApply(rawTitle: rawTitle)
        restoredPanelTitleBoundariesByPanelId[panelId] = boundary
        return shouldApply
    }

    /// Advances admission from authoritative shell activity and returns a buffered genuine title.
    func restoredPanelTitleAfterShellActivity(
        panelId: UUID,
        state: PanelShellActivityState
    ) -> String? {
        guard var boundary = restoredPanelTitleBoundariesByPanelId[panelId] else {
            return nil
        }
        let pendingTitle = boundary.observe(shellState: state)
        switch (boundary.phase, state) {
        case (.awaitingUserCommand, .commandRunning):
            restoredPanelTitleBoundariesByPanelId.removeValue(forKey: panelId)
        default:
            restoredPanelTitleBoundariesByPanelId[panelId] = boundary
        }
        return pendingTitle
    }
}
