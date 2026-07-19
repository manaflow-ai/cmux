/// Restarts the Computer Use helper after an unexpected termination while the feature is enabled.
@MainActor
final class ComputerUseHelperSupervisor {
    private let restart: @MainActor () async -> Void
    private var isEnabled = false

    init(restart: @escaping @MainActor () async -> Void) {
        self.restart = restart
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func helperDidTerminate() async {
        guard isEnabled else { return }
        await restart()
    }
}
