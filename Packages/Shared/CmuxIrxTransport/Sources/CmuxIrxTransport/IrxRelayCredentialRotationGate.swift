/// Serializes relay-credential rotation ownership across autopilot lifecycles.
/// An old broker request may finish after its task is cancelled, so the
/// endpoint checks this actor before every live endpoint mutation.
actor IrxRelayCredentialRotationGate {
    private var generation: UInt64 = 0

    func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration
    }
}
