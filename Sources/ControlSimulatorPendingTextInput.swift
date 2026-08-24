import CmuxSimulatorUI
import Foundation

@MainActor
final class ControlSimulatorPendingTextInput {
    private weak var coordinator: SimulatorPaneCoordinator?
    private var task: Task<Void, Never>?
    private var requestIdentifier: UUID?
    private var isCancelled = false
    private var taskFinished = false

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
    }

    func setTask(_ task: Task<Void, Never>) {
        if isCancelled {
            task.cancel()
        } else if !taskFinished {
            self.task = task
        }
    }

    func finishTask() {
        taskFinished = true
        task = nil
    }

    func setRequestIdentifier(_ requestIdentifier: UUID) {
        self.requestIdentifier = requestIdentifier
        if isCancelled {
            coordinator?.cancelTextInput(requestID: requestIdentifier)
        }
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
        guard let requestIdentifier else { return }
        coordinator?.cancelTextInput(requestID: requestIdentifier)
    }
}
