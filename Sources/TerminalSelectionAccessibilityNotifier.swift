import AppKit

@MainActor
final class TerminalSelectionAccessibilityNotifier {
    private var debounceTimer: Timer?

    func schedule(for element: NSView) {
        debounceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self, weak element] timer in
            guard let self, self.debounceTimer === timer, let element else { return }
            self.debounceTimer = nil
            NSAccessibility.post(element: element, notification: .selectedTextChanged)
        }
        debounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        debounceTimer?.invalidate()
    }
}

extension GhosttyNSView {
    func handleSelectionChangedAction() -> Bool {
        selectionAccessibilityNotifier.schedule(for: self)
        return true
    }
}
