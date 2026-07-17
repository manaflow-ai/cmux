public import Observation

/// Scene-local coordinator for mobile toast presentation.
///
/// The presenter shows one toast, keeps a bounded queue, coalesces repeated
/// events, and lets warnings or errors supersede lower-priority updates.
@MainActor
@Observable
public final class MobileToastPresenter {
    private let maximumQueueDepth: Int
    var currentPresentation: MobileToastPresentation?
    @ObservationIgnored private var queuedPresentations: [MobileToastPresentation] = []

    /// Creates a presenter with space for two waiting toasts.
    public init() {
        maximumQueueDepth = 2
    }

    init(maximumQueueDepth: Int) {
        self.maximumQueueDepth = max(0, maximumQueueDepth)
    }

    /// Presents a toast.
    ///
    /// A matching coalescing key replaces the older event. A warning or error
    /// supersedes the visible lower-priority toast. Other events wait in a
    /// two-item queue.
    public func present(
        _ toast: MobileToast,
        onDismiss: (@MainActor @Sendable (MobileToastDismissReason) -> Void)? = nil
    ) {
        let incoming = MobileToastPresentation(toast: toast, onDismiss: onDismiss)

        if let key = toast.coalescingKey,
           currentPresentation?.toast.coalescingKey == key {
            let replaced = currentPresentation
            currentPresentation = incoming
            replaced?.onDismiss?(.replaced)
            return
        }

        if let key = toast.coalescingKey,
           let index = queuedPresentations.firstIndex(where: { $0.toast.coalescingKey == key }) {
            let replaced = queuedPresentations[index]
            queuedPresentations[index] = incoming
            replaced.onDismiss?(.replaced)
            return
        }

        guard let currentPresentation else {
            self.currentPresentation = incoming
            return
        }

        if toast.tone.priority > currentPresentation.toast.tone.priority {
            self.currentPresentation = incoming
            currentPresentation.onDismiss?(.replaced)
            return
        }

        guard maximumQueueDepth > 0 else {
            onDismiss?(.replaced)
            return
        }

        queuedPresentations.append(incoming)
        if queuedPresentations.count > maximumQueueDepth {
            let dropped = queuedPresentations.removeFirst()
            dropped.onDismiss?(.replaced)
        }
    }

    /// Dismisses the visible toast if its identity still matches.
    public func dismiss(id: MobileToast.ID, reason: MobileToastDismissReason = .programmatic) {
        guard currentPresentation?.toast.id == id else { return }
        let dismissed = currentPresentation
        currentPresentation = queuedPresentations.isEmpty ? nil : queuedPresentations.removeFirst()
        dismissed?.onDismiss?(reason)
    }

    /// Dismisses visible and queued events with a matching coalescing key.
    public func dismiss(coalescingKey: String) {
        let removed = queuedPresentations.filter { $0.toast.coalescingKey == coalescingKey }
        queuedPresentations.removeAll { $0.toast.coalescingKey == coalescingKey }
        let dismissed = currentPresentation?.toast.coalescingKey == coalescingKey
            ? currentPresentation
            : nil
        if dismissed != nil {
            currentPresentation = queuedPresentations.isEmpty ? nil : queuedPresentations.removeFirst()
        }

        dismissed?.onDismiss?(.programmatic)
        removed.forEach { $0.onDismiss?(.programmatic) }
    }

    /// Runs the visible toast's action and dismisses that same toast.
    public func performAction(id: MobileToast.ID) {
        guard let presentation = currentPresentation,
              presentation.toast.id == id,
              let action = presentation.toast.action
        else { return }
        action.handler()
        dismiss(id: id, reason: .action)
    }

    var queuedCount: Int {
        queuedPresentations.count
    }

    var queuedToasts: [MobileToast] {
        queuedPresentations.map(\.toast)
    }
}
