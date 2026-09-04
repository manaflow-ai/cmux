import Foundation

/// Owns a best-effort coordinator cancellation for a file-backed panel.
///
/// Normal panel teardown calls ``cancel()`` synchronously. The deinitializer is
/// a safety net for ownership-drop paths that release a panel without calling
/// its ``Panel.close()`` hook; the coordinator removal is delivered back to the
/// main actor because the coordinator owns main-actor state.
final class FileContentObservationLifetime {
    private let cancelAction: () -> Void
    private var isCancelled = false

    init(cancelAction: @escaping () -> Void) {
        self.cancelAction = cancelAction
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelAction()
    }

    deinit {
        cancel()
    }
}
