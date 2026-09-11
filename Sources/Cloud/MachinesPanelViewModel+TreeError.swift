import Foundation

extension MachinesPanelViewModel {
    /// Records a tree operation failure without replacing a useful retry/details path.
    func noteTreeFailure(_ description: String) {
        operationError.report(description)
        objectWillChange.send()
    }

    func dismissTreeError(_ id: UUID) {
        operationError.dismiss(id)
        objectWillChange.send()
    }
}
