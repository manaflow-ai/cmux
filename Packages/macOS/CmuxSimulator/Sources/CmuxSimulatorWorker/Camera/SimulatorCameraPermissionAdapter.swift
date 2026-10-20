import CmuxSimulator
import Foundation

struct SimulatorCameraPermissionAdapter: Sendable {
    typealias Authorization = @Sendable (
        String,
        String
    ) async throws -> SimulatorPrivacyAuthorization
    typealias Mutation = @Sendable (
        String,
        SimulatorPrivacyAction,
        SimulatorPrivacyService,
        String
    ) async throws -> Void

    private let authorization: Authorization
    private let mutation: Mutation
    private let authorizationStore: SimulatorCameraAuthorizationStore

    init(
        subprocessRunner: SimulatorSubprocessRunner,
        authorizationStore: SimulatorCameraAuthorizationStore =
            SimulatorCameraAuthorizationStore()
    ) {
        let privacy = SimulatorPrivatePrivacyAdapter(subprocessRunner: subprocessRunner)
        authorization = { deviceIdentifier, bundleIdentifier in
            try await privacy.cameraAuthorizationWithoutMutationGate(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        }
        mutation = { deviceIdentifier, action, service, bundleIdentifier in
            try await privacy.setTCCWithoutMutationGate(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier,
                action: action,
                service: service
            )
        }
        self.authorizationStore = authorizationStore
    }

    init(
        authorization: @escaping Authorization = { _, _ in .notDetermined },
        authorizationStore: SimulatorCameraAuthorizationStore =
            SimulatorCameraAuthorizationStore(
                directory: FileManager().temporaryDirectory.appendingPathComponent(
                    "cmux-camera-authorization-test-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
        mutation: @escaping Mutation
    ) {
        self.authorization = authorization
        self.mutation = mutation
        self.authorizationStore = authorizationStore
    }

    func grant(deviceIdentifier: String, bundleIdentifier: String) async throws {
        let savedAuthorization: SimulatorPrivacyAuthorization
        if let existingAuthorization = try await authorizationStore.authorization(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        ) {
            savedAuthorization = existingAuthorization
        } else {
            savedAuthorization = try await authorization(
                deviceIdentifier,
                bundleIdentifier
            )
        }
        // Saving every grant preserves the original authorization while adopting
        // this worker's live host identity before recovery can classify the journal.
        try await authorizationStore.save(
            savedAuthorization,
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        try await mutation(deviceIdentifier, .grant, .camera, bundleIdentifier)
    }

    func restore(deviceIdentifier: String, bundleIdentifier: String) async throws {
        guard let priorAuthorization = try await authorizationStore.authorization(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        ) else { return }
        let action: SimulatorPrivacyAction = switch priorAuthorization {
        case .notDetermined: .reset
        case .denied: .revoke
        case .granted: .grant
        default:
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                String(
                    localized: "simulator.failure.cameraAuthorizationRestore",
                    defaultValue:
                        "The saved Simulator camera authorization could not be restored."
                )
            )
        }
        try await mutation(deviceIdentifier, action, .camera, bundleIdentifier)
        try await authorizationStore.remove(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
    }
}
