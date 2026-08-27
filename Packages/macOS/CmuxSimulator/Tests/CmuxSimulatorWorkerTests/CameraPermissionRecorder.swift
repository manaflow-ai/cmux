import CmuxSimulator

actor CameraPermissionRecorder {
    typealias Mutation = (
        device: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundle: String
    )

    private let initialAuthorization: SimulatorPrivacyAuthorization
    private(set) var mutations: [Mutation] = []

    init(initialAuthorization: SimulatorPrivacyAuthorization = .notDetermined) {
        self.initialAuthorization = initialAuthorization
    }

    var mutation: Mutation? { mutations.last }

    func authorization(
        device: String,
        bundle: String
    ) -> SimulatorPrivacyAuthorization {
        initialAuthorization
    }

    func record(
        device: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundle: String
    ) {
        mutations.append((device, action, service, bundle))
    }
}
