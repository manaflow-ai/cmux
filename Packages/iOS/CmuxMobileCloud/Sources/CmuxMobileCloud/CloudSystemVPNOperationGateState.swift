extension CloudSystemVPNOperationGate {
    @MainActor
    final class State {
        var acquired = false
        var cancelledBeforeAcquisition = false
        var cancellationRequested = false
        var finished = false
        var abandonmentTask: Task<Void, Never>?
    }
}
