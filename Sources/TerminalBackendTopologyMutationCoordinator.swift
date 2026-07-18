import CmuxTerminal
import Foundation

/// One fail-closed entrypoint for user-initiated terminal topology changes.
@MainActor
final class TerminalBackendTopologyMutationCoordinator {
    typealias FailureReporter = @MainActor (String) -> Void

    private let failureReporter: FailureReporter

    init(failureReporter: @escaping FailureReporter = { _ in }) {
        self.failureReporter = failureReporter
    }

    static let supportedMutations: Set<TerminalBackendTopologyMutation> = [
        .closeTerminal,
        .reparentTerminal,
    ]

    @discardableResult
    func requestReparent(
        _ panel: TerminalPanel,
        to workspaceID: UUID
    ) -> Bool {
        guard panel.surface.requestCanonicalReparent(to: workspaceID).accepted else {
            reportFailure(for: .reparentTerminal)
            return false
        }
        return true
    }

    @discardableResult
    func requestClose(_ panel: TerminalPanel) -> Bool {
        guard panel.surface.requestCanonicalClose().accepted else {
            reportFailure(for: .closeTerminal)
            return false
        }
        return true
    }

    @discardableResult
    func reject(_ mutation: TerminalBackendTopologyMutation) -> Bool {
        precondition(!Self.supportedMutations.contains(mutation))
        failureReporter(rejectionMessage(for: mutation))
        return false
    }

    func rejectionMessage(for mutation: TerminalBackendTopologyMutation) -> String {
        String(
            localized: "terminalBackend.topology.mutationUnavailable",
            defaultValue: "The terminal backend cannot commit this layout change yet (\(mutation.rawValue)). Your current layout was left unchanged."
        )
    }

    private func reportFailure(for mutation: TerminalBackendTopologyMutation) {
        failureReporter(rejectionMessage(for: mutation))
    }
}
