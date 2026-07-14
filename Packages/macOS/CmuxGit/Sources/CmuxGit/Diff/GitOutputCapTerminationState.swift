struct GitOutputCapTerminationState {
    private(set) var didTerminateForOutputCap = false

    mutating func record(didSignalLiveProcess: Bool) {
        didTerminateForOutputCap = didTerminateForOutputCap || didSignalLiveProcess
    }
}
