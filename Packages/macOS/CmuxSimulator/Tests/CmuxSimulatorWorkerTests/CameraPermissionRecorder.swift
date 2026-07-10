import CmuxSimulator

actor CameraPermissionRecorder {
    private(set) var mutation: (
        device: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundle: String
    )?

    func record(
        device: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundle: String
    ) {
        mutation = (device, action, service, bundle)
    }
}
