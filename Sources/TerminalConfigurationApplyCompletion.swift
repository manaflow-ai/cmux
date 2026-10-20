/// Main-actor ownership box for a completion passed into a sendable scheduled
/// action without requiring legacy callers to become sendable themselves.
@MainActor
final class TerminalConfigurationApplyCompletion {
    private var action: (@MainActor () -> Void)?

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func finish() {
        let action = self.action
        self.action = nil
        action?()
    }
}
