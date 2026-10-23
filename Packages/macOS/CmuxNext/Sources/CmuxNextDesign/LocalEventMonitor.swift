import AppKit

/// One `NSEvent` local monitor, held by the object that installed it until ``remove()``.
///
/// `NSEvent.addLocalMonitorForEvents` hands back an opaque `Any`, which an owner's
/// `nonisolated deinit` cannot read (it is not `Sendable`). Held in this main-actor class
/// instead, the deinit can pass the monitor to the main thread to remove
/// (`MainDelivery().run { monitor.remove() }`): inline when the owner is released on main, a
/// hop from any other thread. The installing code keeps its handler closure where it was:
///
/// ```swift
/// monitor = LocalEventMonitor(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
///     self?.handle(event) ?? event
/// })
/// ```
@MainActor
final class LocalEventMonitor {
    private var token: Any?

    /// Holds `token`, the value `NSEvent.addLocalMonitorForEvents` returned (nil: none was installed).
    init(_ token: Any?) {
        self.token = token
    }

    /// Removes the monitor; later calls do nothing.
    func remove() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }
}
