import AppKit

@MainActor
final class TerminalSelectionAccessibilityNotifier {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let sleep: Sleep
    private var pendingTask: Task<Void, Never>?

    init(
        sleep: @escaping Sleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.sleep = sleep
    }

    func schedule(for element: NSView) {
        pendingTask?.cancel()
        let sleep = self.sleep
        pendingTask = Task { @MainActor [weak element] in
            do {
                try await sleep(.milliseconds(100))
            } catch {
                return
            }
            guard !Task.isCancelled, let element else { return }
            NSAccessibility.post(element: element, notification: .selectedTextChanged)
        }
    }

    deinit {
        pendingTask?.cancel()
    }
}

extension GhosttyNSView {
    func handleSelectionChangedAction() -> Bool {
        selectionAccessibilityNotifier.schedule(for: self)
        return true
    }
}
