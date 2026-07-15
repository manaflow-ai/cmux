import CmuxControlSocket
import CmuxSimulator
import CmuxSimulatorUI
import Foundation

enum ResolvedSimulatorPanel {
    case panel(SimulatorPanel)
    case failure(ControlSimulatorTargetFailure)
}

/// Native Simulator-domain routing and coordinator integration.
extension TerminalController: ControlSimulatorContext {
    func controlSimulatorBeginType(
        routing: ControlRoutingSelectors,
        text: String
    ) -> ControlSimulatorTypeStartResolution {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else { return .inputUnavailable }
        switch resolveSimulatorPanel(routing: routing) {
        case let .failure(failure):
            return .failed(failure)
        case let .panel(panel):
            let receipt = ControlSimulatorCompletionReceipt()
            let coordinator = panel.coordinator
            switch coordinator.beginTypeText(text, completion: { succeeded in
                receipt.complete(succeeded ? .succeeded : .failed)
            }) {
            case let .success(submission):
                receipt.installCancellation { [weak coordinator] in
                    Task { @MainActor in
                        coordinator?.cancelTextInput(requestID: submission.requestIdentifier)
                    }
                }
                return .started(
                    surfaceID: panel.id,
                    characterCount: submission.characterCount,
                    completionTimeoutSeconds: submission.completionTimeoutSeconds,
                    receipt: receipt
                )
            case let .failure(error):
                switch error {
                case .encoding(.empty):
                    return .emptyText
                case let .encoding(.tooLong(_, maximum)):
                    return .textTooLong(maximumUTF8ByteCount: maximum)
                case let .encoding(.unsupportedScalar(value, index)):
                    return .unsupportedCharacter(scalarIndex: index, scalarValue: value)
                case .encoding(.malformedSequence), .deliveryUnavailable:
                    return .deliveryUnavailable
                case .inputUnavailable:
                    return .inputUnavailable
                }
            }
        }
    }

    func resolveSimulatorPanel(routing: ControlRoutingSelectors) -> ResolvedSimulatorPanel {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .failure(.tabManagerUnavailable)
        }

        let workspace: Workspace?
        if let workspaceID = routing.workspaceID {
            workspace = tabManager.tabs.first(where: { $0.id == workspaceID })
            guard workspace != nil else { return .failure(.workspaceNotFound) }
        } else if let surfaceID = routing.surfaceID {
            workspace = tabManager.tabs.first(where: { $0.panels[surfaceID] != nil })
            guard workspace != nil else { return .failure(.surfaceNotFound(surfaceID)) }
        } else {
            workspace = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager)
            guard workspace != nil else { return .failure(.workspaceNotFound) }
        }
        guard let workspace else { return .failure(.workspaceNotFound) }
        guard !workspace.isRemoteTmuxMirror else { return .failure(.remoteWorkspace) }

        if let surfaceID = routing.surfaceID {
            guard let panel = workspace.panels[surfaceID] else {
                return .failure(.surfaceNotFound(surfaceID))
            }
            guard let simulator = panel as? SimulatorPanel else {
                return .failure(.surfaceNotSimulator(surfaceID))
            }
            return .panel(simulator)
        }

        if let focusedID = workspace.focusedPanelId,
           let focused = workspace.panels[focusedID] as? SimulatorPanel {
            return .panel(focused)
        }
        let simulators = workspace.panels.values.compactMap { $0 as? SimulatorPanel }
        switch simulators.count {
        case 1:
            return .panel(simulators[0])
        case 0:
            if let focusedID = workspace.focusedPanelId,
               workspace.panels[focusedID] != nil {
                return .failure(.surfaceNotSimulator(focusedID))
            }
            return .failure(.simulatorNotFound)
        default:
            return .failure(.ambiguousSimulatorSurfaces(simulators.count))
        }
    }

}
