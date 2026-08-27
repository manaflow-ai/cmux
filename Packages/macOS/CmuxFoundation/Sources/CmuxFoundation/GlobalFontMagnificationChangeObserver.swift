public import Foundation

/// Observes global font magnification changes for AppKit-backed views.
///
/// Retain this object for as long as the observed view or controller needs
/// live font updates. The handler is delivered on the main actor after
/// ``GlobalFontMagnification/didChangeNotification`` posts, and observation is
/// automatically removed when the observer deinitializes.
public final class GlobalFontMagnificationChangeObserver {
    private let notificationCenter: NotificationCenter
    private var notificationObserver: (any NSObjectProtocol)?

    /// Creates an observer that invokes `handler` when the global percent changes.
    ///
    /// - Parameters:
    ///   - notificationCenter: The notification center that posts
    ///     ``GlobalFontMagnification/didChangeNotification``.
    ///   - handler: Main-actor work that reapplies derived fonts or layout.
    public init(notificationCenter: NotificationCenter = .default, handler: @MainActor @escaping () -> Void) {
        self.notificationCenter = notificationCenter
        notificationObserver = notificationCenter.addObserver(
            forName: GlobalFontMagnification.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
    }

    deinit {
        if let notificationObserver {
            notificationCenter.removeObserver(notificationObserver)
        }
    }
}
