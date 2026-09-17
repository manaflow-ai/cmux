internal import CmuxTerminalFrontend

final class BackendOnlyPresentationLease: TerminalExternalPresentationLease, Sendable {
    private let detachAction: @Sendable () -> Void

    init(detachAction: @escaping @Sendable () -> Void) {
        self.detachAction = detachAction
    }

    nonisolated func detach() {
        detachAction()
    }

    deinit {
        detach()
    }
}
