import AppKit

/// When a window's host pressure indicator samples the host (cmux#22662: a new dev
/// surface ships off). It samples only while the Debug Settings toggle
/// `hostPressure.enabled` is on and its window can be seen: in a window, not
/// minimized, and not fully occluded (hidden app, another Space, covered).
/// Everything else (toggle off, hidden, minimized, occluded, closed) means no
/// subscription, so no service, no monitor, no 15 s timer and no reads.
struct HostPressureSampling: Equatable {
    var enabled: Bool
    var windowVisible: Bool

    var samples: Bool { enabled && windowVisible }

    /// Whether `window` can be seen right now.
    static func isVisible(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// The window notifications after which `isVisible` may differ.
    static let windowChanges: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
    ]
}
