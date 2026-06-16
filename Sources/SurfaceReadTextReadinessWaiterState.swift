enum SurfaceReadTextReadinessWaiterState {
    case pending
    case waiting(CheckedContinuation<Bool, Never>)
    case ready
}
