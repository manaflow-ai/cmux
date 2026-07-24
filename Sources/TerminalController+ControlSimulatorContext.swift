import CmuxControlSocket
import CmuxSimulator
import CmuxSimulatorUI
import Foundation

enum ResolvedSimulatorPanel {
    case panel(SimulatorPanel)
    case unavailable
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
        case .unavailable:
            return .inputUnavailable
        case let .failure(failure):
            return .failed(failure)
        case let .panel(panel):
            let sequence: SimulatorTextInputSequence
            do {
                sequence = try SimulatorUSKeyboardTextEncoder().encode(text)
            } catch let error as SimulatorTextInputEncodingError {
                return controlSimulatorTypeResolution(for: error)
            } catch {
                return .deliveryUnavailable
            }
            let receipt = ControlSimulatorCompletionReceipt()
            let coordinator = panel.coordinator
            let pending = ControlSimulatorPendingTextInput(coordinator: coordinator)
            let task = Task { @MainActor [weak coordinator, pending] in
                defer { pending.finishTask() }
                guard let coordinator else {
                    receipt.complete(.failed)
                    return
                }
                await coordinator.start()
                do {
                    try Task.checkCancellation()
                    try await coordinator.waitForSelectedDeviceStreaming()
                    try Task.checkCancellation()
                } catch {
                    receipt.complete(.failed)
                    return
                }
                guard coordinator.supports(.keyboard) else {
                    receipt.complete(.failed)
                    return
                }
                switch coordinator.beginTypeText(text, completion: { succeeded in
                    receipt.complete(succeeded ? .succeeded : .failed)
                }) {
                case let .success(submission):
                    pending.setRequestIdentifier(submission.requestIdentifier)
                case .failure:
                    receipt.complete(.failed)
                }
            }
            pending.setTask(task)
            receipt.installCancellation { pending.cancel() }
            return .started(
                surfaceID: panel.id,
                characterCount: sequence.characterCount,
                completionTimeoutSeconds: sequence.completionTimeoutSeconds
                    + simulatorOperationDeadlines.textInputReadiness,
                receipt: receipt
            )
        }
    }

    private func controlSimulatorTypeResolution(
        for error: SimulatorTextInputEncodingError
    ) -> ControlSimulatorTypeStartResolution {
        switch error {
        case .empty:
            return .emptyText
        case let .tooLong(_, maximum):
            return .textTooLong(maximumUTF8ByteCount: maximum)
        case let .unsupportedScalar(value, index):
            return .unsupportedCharacter(scalarIndex: index, scalarValue: value)
        case .malformedSequence:
            return .deliveryUnavailable
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
            return resolveReadySimulatorPanel(simulator)
        }

        if let paneID = routing.paneID {
            guard let pane = workspace.bonsplitController.allPaneIds.first(where: {
                $0.id == paneID
            }) else {
                return .failure(.simulatorNotFound)
            }
            if let selected = workspace.bonsplitController.selectedTab(inPane: pane),
               let simulator = workspace.panel(for: selected.id) as? SimulatorPanel {
                return resolveReadySimulatorPanel(simulator)
            }
            let simulators = workspace.bonsplitController.tabs(inPane: pane).compactMap {
                workspace.panel(for: $0.id) as? SimulatorPanel
            }
            switch simulators.count {
            case 1:
                return resolveReadySimulatorPanel(simulators[0])
            case 0:
                if let selected = workspace.bonsplitController.selectedTab(inPane: pane),
                   let panel = workspace.panel(for: selected.id) {
                    return .failure(.surfaceNotSimulator(panel.id))
                }
                return .failure(.simulatorNotFound)
            default:
                return .failure(.ambiguousSimulatorSurfaces(simulators.count))
            }
        }

        if let focusedID = workspace.focusedPanelId,
           let focused = workspace.panels[focusedID] as? SimulatorPanel {
            return resolveReadySimulatorPanel(focused)
        }
        let simulators = workspace.panels.values.compactMap { $0 as? SimulatorPanel }
        switch simulators.count {
        case 1:
            return resolveReadySimulatorPanel(simulators[0])
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

    private func resolveReadySimulatorPanel(_ panel: SimulatorPanel) -> ResolvedSimulatorPanel {
        panel.isFeatureReady ? .panel(panel) : .unavailable
    }

}

private final class ControlSimulatorPendingTextInput: @unchecked Sendable {
    private let lock = NSLock()
    private weak var coordinator: SimulatorPaneCoordinator?
    private var task: Task<Void, Never>?
    private var requestIdentifier: UUID?
    private var isCancelled = false
    private var taskFinished = false

    @MainActor
    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
    }

    func setTask(_ task: Task<Void, Never>) {
        lock.withLock {
            if isCancelled {
                task.cancel()
            } else if !taskFinished {
                self.task = task
            }
        }
    }

    func finishTask() {
        lock.withLock {
            taskFinished = true
            task = nil
        }
    }

    @MainActor
    func setRequestIdentifier(_ requestIdentifier: UUID) {
        let shouldCancel = lock.withLock {
            self.requestIdentifier = requestIdentifier
            return isCancelled
        }
        if shouldCancel {
            coordinator?.cancelTextInput(requestID: requestIdentifier)
        }
    }

    func cancel() {
        let state = lock.withLock { () -> (Task<Void, Never>?, UUID?) in
            isCancelled = true
            return (task, requestIdentifier)
        }
        state.0?.cancel()
        guard let requestIdentifier = state.1 else { return }
        Task { @MainActor [weak coordinator] in
            coordinator?.cancelTextInput(requestID: requestIdentifier)
        }
    }
}
