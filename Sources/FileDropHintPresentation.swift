import AppKit
import CmuxFoundation

/// Owns only drag feedback. Dismissing a hint must not cancel WebKit's drop delivery.
@MainActor
final class FileDropHintPresentation: NSObject {
    private enum Phase: Equatable {
        case idle
        case tracking(Int)
        case dismissed(Int)
    }

    let badge = FileDropHintBadgeView(frame: .zero)
    private weak var hostWindow: NSWindow?
    private var phase = Phase.idle
    private var eventMonitor: Any?
    private let displayDuration: Duration
    private var deadline: MainActorCoalescingDeadlineTimer<FileDropHintPresentation>?

    init(displayDuration: Duration = .seconds(8)) {
        self.displayDuration = displayDuration
        super.init()
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window else { return }
        dismiss()
        let center = NotificationCenter.default
        center.removeObserver(self)
        hostWindow = window
        guard let window else { return }

        // AppKit delivers these lifecycle notifications synchronously on the main thread.
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(environmentDidChange(_:)), name: name, object: window)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(self, selector: #selector(environmentDidChange(_:)), name: name, object: nil)
        }
    }

    func begin(sequenceNumber: Int) {
        if phase == .tracking(sequenceNumber) || phase == .dismissed(sequenceNumber) {
            // AppKit may re-enter a destination after focus changes during the same drag.
            // Its feedback stays dismissed until a genuinely new native session arrives.
            return
        }
        dismiss()
        phase = .tracking(sequenceNumber)
    }

    func show(sequenceNumber: Int, text: String, centeredIn target: CGRect, clippedTo bounds: CGRect) {
        guard case .tracking(let current) = phase, current == sequenceNumber, hostWindow != nil else { return }
        badge.show(text: text, centeredIn: target, clippedTo: bounds)
        if deadline == nil {
            // A genuine display deadline driven by synchronous AppKit callbacks, not a retry.
            deadline = MainActorCoalescingDeadlineTimer(owner: self) { $0.dismiss() }
        }
        if deadline?.isScheduled == false {
            deadline?.schedule(after: displayDuration)
        }
        installEventMonitorIfNeeded()
    }

    func hideBadge() {
        badge.hideImmediately()
    }

    func dismiss() {
        if case .tracking(let sequenceNumber) = phase {
            phase = .dismissed(sequenceNumber)
        }
        deadline?.cancel()
        badge.hideImmediately()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    /// Preserve the native end/cancel event so AppKit can also remove the source drag image.
    func handleEvent(_ event: NSEvent) -> NSEvent {
        switch event.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp,
             .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .keyDown:
            dismiss()
        case .flagsChanged:
            hideBadge()
        default:
            break
        }
        return event
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp,
                       .leftMouseDown, .rightMouseDown, .otherMouseDown,
                       .mouseMoved, .keyDown, .flagsChanged]
        ) { [weak self] event in
            self?.handleEvent(event) ?? event
        }
    }

    @objc private func environmentDidChange(_ notification: Notification) {
        if notification.name == NSWindow.didBecomeKeyNotification,
           notification.object as? NSWindow === hostWindow {
            return
        }
        dismiss()
    }
}
