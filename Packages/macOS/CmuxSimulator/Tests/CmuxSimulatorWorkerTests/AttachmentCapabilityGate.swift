import CmuxSimulator

actor AttachmentCapabilityGate {
    private var continuation: CheckedContinuation<Set<SimulatorCapability>, Never>?
    private var releasedCapabilities: Set<SimulatorCapability>?

    func wait() async -> Set<SimulatorCapability> {
        if let releasedCapabilities {
            return releasedCapabilities
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ capabilities: Set<SimulatorCapability>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: capabilities)
        } else {
            releasedCapabilities = capabilities
        }
    }
}
