import AppKit

/// One other-app monitor of ``InputEventTap/globalObserve(_:_:)``: the seam adapter between AppKit's
/// global monitor callback and the main actor.
final class GlobalMonitor {
    let flag: InputSubscriptionFlag
    private let handler: @MainActor (NSEvent) -> Void
    private var token: Any?

    /// Installs AppKit's global monitor for `mask`.
    init(_ mask: NSEvent.EventTypeMask, flag: InputSubscriptionFlag, handler: @escaping @MainActor (NSEvent) -> Void) {
        self.flag = flag
        self.handler = handler
        token = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.deliver(event) } // main-proof: NSEvent.h: monitor handlers are called on the main thread
        }
    }

    func deliver(_ event: NSEvent) {
        guard !flag.isCancelled else { return remove() }
        handler(event)
    }

    func remove() {
        guard let token else { return }
        self.token = nil
        NSEvent.removeMonitor(token)
    }
}
