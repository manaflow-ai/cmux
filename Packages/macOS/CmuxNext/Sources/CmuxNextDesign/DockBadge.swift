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

    /// Follows the app's activation policy (``activationPolicies(of:)``) until `policies` ends: each
    /// return to `.regular` (the Dock icon is back after a windowless spell as a menu bar app) shows
    /// the badge again. The Dock drops a badge with the icon while `NSDockTile.badgeLabel` keeps
    /// reading it, so an equal write would show nothing: it clears, then sets.
    public func follow(_ policies: AsyncStream<NSApplication.ActivationPolicy>) async {
        for await policy in policies where policy == .regular {
            guard let label else { continue }
            tile.badgeLabel = nil
            tile.badgeLabel = label
        }
    }

    /// The activation policy of `app` each time it changes (`NSRunningApplication` is KVO-observable,
    /// its only change signal), until the stream's consumer stops.
    ///
    /// KVO keeps no reference to the object it observes, and `NSRunningApplication.current` hands out
    /// an instance nothing else may hold: the stream holds `app` until it ends, invalidates the
    /// observation, and only then lets `app` go. An app freed while still observed made the
    /// observation's teardown crash on it (signal 11 in -[NSRunningApplication
    /// removeObserver:forKeyPath:], cmux#26809).
    public static func activationPolicies(of app: NSRunningApplication = .current) -> AsyncStream<NSApplication.ActivationPolicy> {
        // Only the newest policy matters: a burst of flips settles on the last.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // crash-allow: the token is never mutated; it is only invalidated (thread-safe), once, when the stream ends.
            nonisolated(unsafe) let token = app.observe(\.activationPolicy, options: [.new]) { app, _ in
                continuation.yield(app.activationPolicy)
            }
            // crash-allow: read by no one; held only so the observed app outlives its observation, released once after it.
            nonisolated(unsafe) let observed = app
            continuation.onTermination = { _ in
                token.invalidate()
                withExtendedLifetime(observed) {}
            }
        }
    }
}
