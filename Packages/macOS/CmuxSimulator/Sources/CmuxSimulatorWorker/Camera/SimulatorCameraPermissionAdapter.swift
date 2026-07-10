import CmuxSimulator

struct SimulatorCameraPermissionAdapter: Sendable {
    typealias Mutation = @Sendable (
        String,
        SimulatorPrivacyAction,
        SimulatorPrivacyService,
        String
    ) async throws -> Void

    private let mutation: Mutation

    init(subprocessRunner: SimulatorSubprocessRunner) {
        let privacy = SimulatorPrivatePrivacyAdapter(subprocessRunner: subprocessRunner)
        mutation = { deviceIdentifier, action, service, bundleIdentifier in
            try await privacy.set(
                deviceIdentifier: deviceIdentifier,
                action: action,
                service: service,
                bundleIdentifier: bundleIdentifier
            )
        }
    }

    init(mutation: @escaping Mutation) {
        self.mutation = mutation
    }

    func grant(deviceIdentifier: String, bundleIdentifier: String) async throws {
        try await mutation(deviceIdentifier, .grant, .camera, bundleIdentifier)
    }
}
