import Foundation

extension CloudOperationGate {
    @MainActor
    final class State {
        var acquired = false
        var cancelledBeforeAcquisition = false
        var operationFinished = false
        var activeHoldIDs: Set<UUID> = []
        var finished = false
        var abandonmentTask: Task<Void, Never>?
    }
}
