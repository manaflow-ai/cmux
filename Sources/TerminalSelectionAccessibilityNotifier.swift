import AppKit

/// Thread-safe, bounded ingress from Ghostty's renderer callback into the UI.
/// `bufferingNewest(1)` keeps at most one undelivered event per surface, so a
/// stalled main actor cannot accumulate one task per drag update.
final class TerminalSelectionAccessibilitySignal: Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    nonisolated init() {
        let (events, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.events = events
        self.continuation = continuation
    }

    /// Returns true when the event occupied the one buffer slot. False means
    /// it replaced an older pending event or the surface has already stopped.
    @discardableResult
    nonisolated func request() -> Bool {
        switch continuation.yield(()) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    nonisolated func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}

@MainActor
final class TerminalSelectionAccessibilityNotifier {
    private var debounceTimer: Timer?
    private var eventsTask: Task<Void, Never>?
    private weak var element: NSView?

    init(element: NSView, events: AsyncStream<Void>) {
        self.element = element
        eventsTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { return }
                self.schedule()
            }
        }
    }

    private func schedule() {
        debounceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] timer in
            // This timer is registered only on RunLoop.main below.
            MainActor.assumeIsolated {
                guard let self, self.debounceTimer === timer else { return }
                self.debounceTimer = nil
                guard let element = self.element else { return }
                NSAccessibility.post(element: element, notification: .selectedTextChanged)
            }
        }
        debounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        eventsTask?.cancel()
        debounceTimer?.invalidate()
    }
}
