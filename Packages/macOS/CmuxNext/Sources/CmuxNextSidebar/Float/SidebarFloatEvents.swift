import AppKit

/// The app's presses, releases and key ups while the sidebar floats (``SidebarFloat``): a press
/// outside the card closes it, a release or key up may end a hold. One local monitor, kept only
/// while the sidebar floats: the owner calls ``stop()`` when the float ends. Events pass on unchanged.
@MainActor
final class SidebarFloatEvents {
    private var monitor: Any?

    /// Starts watching; `handler` sees each event on the main actor before AppKit delivers it.
    init(_ handler: @escaping @MainActor (NSEvent) -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                              .leftMouseUp, .rightMouseUp, .keyUp]) { event in
            // main-proof: AppKit calls a local event monitor on the main thread, inside its event loop.
            MainActor.assumeIsolated { handler(event) }
            return event
        }
    }

    /// Stops watching.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
