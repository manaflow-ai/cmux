public import Foundation
import Observation

/// Tracks which browser panel currently owns address-bar (omnibar) focus, and
/// owns the omnibar selection-repeat coordinator whose lifetime is bound to that
/// focus.
///
/// The cmux app delegate used to inline a single `browserAddressBarFocusedPanelId`
/// optional plus a paired `stopBrowserOmnibarSelectionRepeat()` call at every
/// site that cleared or re-pointed focus. That coupling — "whenever the tracked
/// panel changes or is cleared, the in-flight selection repeat must stop" — is
/// the invariant this tracker encapsulates so no caller can clear focus without
/// stopping the repeat.
///
/// `@MainActor` because every reader and writer is a MainActor UI/event path
/// (the shortcut router, the address-bar focus/blur `NotificationCenter`
/// observers, the web-view first-responder handoff). State lives where its
/// callers live; no actor is warranted.
///
/// The app delegate remains the composition root: it constructs the
/// ``BrowserOmnibarSelectionRepeatCoordinator`` with its `NotificationCenter`
/// selection-move sink and debug-trace sink, hands it to this tracker, and
/// forwards each focus mutation through the tracker. The decision logic that
/// reads AppKit responders, `Workspace`, and `BrowserPanel` to compute *which*
/// panel should be focused stays app-side; only the tracked state and its
/// repeat coupling live here.
@MainActor
@Observable
public final class BrowserOmnibarFocusTracker {
    /// The omnibar selection-repeat coordinator whose active run is stopped
    /// whenever the tracked focus is cleared or re-pointed. Exposed so the app
    /// delegate can forward the per-event repeat lifecycle (dispatch a move,
    /// arm a repeat, note key-up / flags-changed) without a second indirection.
    public let selectionRepeat: BrowserOmnibarSelectionRepeatCoordinator

    /// Identifier of the browser panel that currently owns address-bar focus,
    /// or `nil` when no panel's omnibar is tracked as focused.
    public private(set) var focusedPanelId: UUID?

    /// Creates a focus tracker owning the given selection-repeat coordinator.
    /// - Parameter selectionRepeat: The repeat coordinator to stop on every
    ///   focus clear or re-point. The app delegate injects its effect seams.
    public init(selectionRepeat: BrowserOmnibarSelectionRepeatCoordinator) {
        self.selectionRepeat = selectionRepeat
    }

    /// Marks `panelId` as the panel owning address-bar focus and stops any
    /// in-flight selection repeat, matching the legacy
    /// `browserAddressBarFocusedPanelId = panelId; stopBrowserOmnibarSelectionRepeat()`
    /// pairing the address-bar focus and focus-observer paths performed.
    /// - Parameter panelId: Panel that now owns address-bar focus.
    public func setFocused(panelId: UUID) {
        focusedPanelId = panelId
        selectionRepeat.stopRepeat()
    }

    /// Sets the tracked focused panel without touching the repeat, matching the
    /// legacy `browserAddressBarFocusedPanelId = panel.id` assignment that the
    /// `focusBrowserAddressBar(in:)` path performed before posting the focus
    /// notification. The notification observer is what later stops the repeat.
    /// - Parameter panelId: Panel that now owns address-bar focus.
    public func markFocused(panelId: UUID) {
        focusedPanelId = panelId
    }

    /// Clears tracked focus and stops any in-flight selection repeat only when
    /// the currently tracked panel matches `panelId`, matching the legacy
    /// guarded `clearBrowserAddressBarFocus(panelId:reason:)` and BLUR-observer
    /// behavior.
    /// - Parameter panelId: Panel whose focus should be released.
    /// - Returns: `true` when the tracked panel matched and focus was cleared.
    @discardableResult
    public func clearFocus(ifTrackedPanelId panelId: UUID) -> Bool {
        guard focusedPanelId == panelId else { return false }
        focusedPanelId = nil
        selectionRepeat.stopRepeat()
        return true
    }

    /// Clears tracked focus and stops any in-flight selection repeat
    /// unconditionally, matching the legacy unguarded
    /// `browserAddressBarFocusedPanelId = nil; stopBrowserOmnibarSelectionRepeat()`
    /// sites (the stale-terminal-responder guard and the cross-panel web-view
    /// first-responder handoff).
    public func clearFocus() {
        focusedPanelId = nil
        selectionRepeat.stopRepeat()
    }
}
