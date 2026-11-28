struct SecondaryMacTransportDrainWaiter {
    let continuation: CheckedContinuation<Bool, Never>
    let timeoutTask: Task<Void, Never>
}
