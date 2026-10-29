public import AppKit

/// The Dock icon's unread badge (`notifications.dockBadge`): the label the app last showed, written
/// to the tile only when it changes (writing an equal label would still ask the Dock).
///
/// ```swift
/// let badge = DockBadge(tile: AppDockTile())
/// badge.show(count > 0 ? String(count) : nil)
/// ```
@MainActor
public final class DockBadge {
    private let tile: any DockBadgeTile
    /// The label shown now (nil: no badge).
    public private(set) var label: String?

    /// - Parameter tile: Where the label goes: ``AppDockTile`` in the app, a recorder in tests.
    public init(tile: any DockBadgeTile) {
        self.tile = tile
    }

    /// Shows `label` on the Dock icon (nil: no badge); an equal label writes nothing.
    public func show(_ label: String?) {
        guard label != self.label else { return }
        self.label = label
        tile.badgeLabel = label
    }

    /// Follows the app's activation policy (``activationPolicies(of:)``) until `policies` ends.
    public func follow(_ policies: AsyncStream<NSApplication.ActivationPolicy>) async {
        for await _ in policies {}
    }

    /// The activation policy of `app` each time it changes (`NSRunningApplication` is KVO-observable,
    /// its only change signal), until the stream's consumer stops.
    public static func activationPolicies(of app: NSRunningApplication = .current) -> AsyncStream<NSApplication.ActivationPolicy> {
        // Only the newest policy matters: a burst of flips settles on the last.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // crash-allow: the token is never mutated; it is only invalidated (thread-safe), once, when the stream ends.
            nonisolated(unsafe) let token = app.observe(\.activationPolicy, options: [.new]) { app, _ in
                continuation.yield(app.activationPolicy)
            }
            continuation.onTermination = { _ in token.invalidate() }
        }
    }
}
