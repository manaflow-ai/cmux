public import Foundation

/// The tab-selection-precedence gate for applying a window-local background to a
/// terminal surface.
///
/// Theme/background application is window-local, so a surface should paint the
/// window background only when its tab is the one selected for that window. The
/// precedence is: the owning window's selected tab wins, and only when no owning
/// window manager is known does the decision fall back to the global active tab.
/// During cross-window workspace switches (e.g. jump-to-unread) the global active
/// tab manager can lag behind the owning window, so preferring the owning
/// window's selection keeps the background correct mid-switch.
///
/// The decision is a pure function of `UUID?`/`Bool` primitives with no `self`,
/// AppKit, or runtime reach, so it lives here beside the other terminal-surface
/// decisions and can be unit-tested without an `NSView`, window, or running app.
/// The app-target surface view reads the live `AppDelegate`/`TabManager` state
/// and forwards it through
/// ``shouldApplyWindowBackground(surfaceTabId:owningManagerExists:owningSelectedTabId:activeSelectedTabId:)``.
public struct TerminalSurfaceBackgroundApplicabilityPolicy: Sendable {
    /// The tab id of the surface deciding whether to paint the window background.
    /// `nil` means the surface has no tab context, so the background always applies.
    public var surfaceTabId: UUID?
    /// Whether an owning window tab manager is known for this surface's tab.
    public var owningManagerExists: Bool
    /// The owning window manager's selected tab id, if any. `nil` while the owning
    /// manager's selection is temporarily unresolved.
    public var owningSelectedTabId: UUID?
    /// The global active tab manager's selected tab id, used only as a fallback
    /// when no owning window manager is known.
    public var activeSelectedTabId: UUID?

    /// Creates a policy from the four tab-selection-precedence inputs.
    public init(
        surfaceTabId: UUID?,
        owningManagerExists: Bool,
        owningSelectedTabId: UUID?,
        activeSelectedTabId: UUID?
    ) {
        self.surfaceTabId = surfaceTabId
        self.owningManagerExists = owningManagerExists
        self.owningSelectedTabId = owningSelectedTabId
        self.activeSelectedTabId = activeSelectedTabId
    }

    /// Whether the surface should apply the window-local background under the
    /// captured tab-selection state.
    ///
    /// With no surface tab, the background always applies. When an owning window
    /// manager is known, the background applies only when the owning manager's
    /// selected tab equals the surface tab (or while that selection is
    /// temporarily `nil`). Otherwise the global active selection decides, and
    /// when there is no selection context the background applies.
    public var shouldApplyWindowBackground: Bool {
        guard let surfaceTabId else { return true }
        if owningManagerExists {
            guard let owningSelectedTabId else { return true }
            return owningSelectedTabId == surfaceTabId
        }
        if let activeSelectedTabId {
            return activeSelectedTabId == surfaceTabId
        }
        return true
    }

    /// Convenience that builds the policy from the four inputs and returns the
    /// decision in one call, for sites that do not need to hold the value.
    public static func shouldApplyWindowBackground(
        surfaceTabId: UUID?,
        owningManagerExists: Bool,
        owningSelectedTabId: UUID?,
        activeSelectedTabId: UUID?
    ) -> Bool {
        TerminalSurfaceBackgroundApplicabilityPolicy(
            surfaceTabId: surfaceTabId,
            owningManagerExists: owningManagerExists,
            owningSelectedTabId: owningSelectedTabId,
            activeSelectedTabId: activeSelectedTabId
        ).shouldApplyWindowBackground
    }
}
