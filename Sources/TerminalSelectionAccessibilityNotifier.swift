import AppKit

/// Thread-safe, bounded ingress from Ghostty's renderer callback into the UI.
/// `bufferingNewest(1)` keeps at most one undelivered event per surface, so a
/// stalled main actor cannot accumulate one task per drag update.
final class TerminalSelectionAccessibilitySignal: Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let forcedLock = NSLock()
    // SAFETY: guarded by `forcedLock`.
    nonisolated(unsafe) private var forcedPending = false

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

    /// Requests a post that skips the host's change check.
    ///
    /// Used by Ghostty's selection-changed action, which is authoritative for
    /// selection state. The host's check covers the caret cell only, on purpose:
    /// reading the selection range there would copy the whole selected text on
    /// every rendered frame.
    @discardableResult
    nonisolated func requestForcingPost() -> Bool {
        forcedLock.lock()
        forcedPending = true
        forcedLock.unlock()
        return request()
    }

    /// Reads and clears the forced-post flag.
    nonisolated func consumeForcedPost() -> Bool {
        forcedLock.lock()
        defer { forcedLock.unlock() }
        let pending = forcedPending
        forcedPending = false
        return pending
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
    private let shouldNotify: @MainActor () -> Bool

    /// - Parameter shouldNotify: Consulted on the main actor once per debounce
    ///   window, immediately before posting. Requests arrive on every rendered
    ///   frame, including cursor blinks that move nothing, so the host uses this
    ///   to drop posts when neither the caret nor the selection changed.
    init(
        element: NSView,
        events: AsyncStream<Void>,
        shouldNotify: @MainActor @escaping () -> Bool = { true }
    ) {
        self.element = element
        self.shouldNotify = shouldNotify
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
                guard self.shouldNotify() else { return }
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
