public import AppKit
import os

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
    public static func activationPolicies(of app: NSRunningApplication = .current) -> AsyncStream<NSApplication.ActivationPolicy> {
        activationPolicies(of: app, keyPath: \.activationPolicy)
    }

    /// The same KVO bridge accepts a test-owned observable, without changing the process's Dock policy.
    static func activationPolicies<Object: NSObject>(of app: Object, keyPath: KeyPath<Object, NSApplication.ActivationPolicy>) -> AsyncStream<NSApplication.ActivationPolicy> {
        // Only the newest policy matters: a burst of flips settles on the last.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // KVO does not retain its observed object. Keep it alive until the token is invalidated,
            // then release it even if the stream itself remains retained by a cancelled task. The lock
            // owns the reference, so the termination callback may drop it from any thread.
            let lifetime = OSAllocatedUnfairLock<Object?>(uncheckedState: app)
            let token = app.observe(keyPath, options: [.new]) { source, _ in
                continuation.yield(source[keyPath: keyPath])
            }
            continuation.onTermination = { _ in
                token.invalidate()
                lifetime.withLockUnchecked { $0 = nil }
            }
        }
    }
}
