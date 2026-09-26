import Foundation

/// What the Machines panel says about the machine-list read.
enum MachineListStatus: Equatable {
    case waitingForNetwork
    case reconnecting
    case failed(MachinesPanelViewModel.CloudListProblem)
}

extension MachinesPanelViewModel {
    var listStatus: MachineListStatus? {
        guard hasLoadedOnce, lastErrorDescription != nil else { return nil }
        return .failed(listProblem ?? .unreachable)
    }

    func recoverList() {
        refresh()
    }
}
