public import CmuxBrowser
public import Foundation

/// Inputs the in-window browser portal needs to mount the find-in-page overlay
/// for one panel.
///
/// A plain value bundle of the find ``BrowserSearchState`` plus the focus and
/// navigation callbacks the overlay invokes. The portal builds this from the
/// owning panel and hands it to the overlay host; the host never reaches back
/// into the panel. `canApplyFocusRequest` lets the host gate a focus request by
/// its generation so a stale request does not steal focus after the field has
/// moved on. This type holds closures and a `@MainActor` ``BrowserSearchState``
/// reference, so it is not `Sendable` and is used only on the main actor.
public struct BrowserPortalSearchOverlayConfiguration {
    /// Identifier of the browser panel the overlay belongs to.
    public let panelId: UUID

    /// Observable find-in-page state the overlay reads and binds to.
    public let searchState: BrowserSearchState

    /// Monotonic generation stamped on the latest focus request.
    public let focusRequestGeneration: UInt64

    /// Returns whether a focus request with the given generation should still apply.
    public let canApplyFocusRequest: (UInt64) -> Bool

    /// Advances the selection to the next match.
    public let onNext: () -> Void

    /// Moves the selection to the previous match.
    public let onPrevious: () -> Void

    /// Dismisses the find overlay.
    public let onClose: () -> Void

    /// Notifies the owner that the find field took focus.
    public let onFieldDidFocus: () -> Void

    /// Creates a find-in-page overlay configuration.
    /// - Parameters:
    ///   - panelId: Identifier of the owning browser panel.
    ///   - searchState: Observable find-in-page state to bind.
    ///   - focusRequestGeneration: Generation stamp of the latest focus request.
    ///   - canApplyFocusRequest: Gate that approves a focus request by generation.
    ///   - onNext: Advances to the next match.
    ///   - onPrevious: Moves to the previous match.
    ///   - onClose: Dismisses the overlay.
    ///   - onFieldDidFocus: Reports that the find field took focus.
    public init(
        panelId: UUID,
        searchState: BrowserSearchState,
        focusRequestGeneration: UInt64,
        canApplyFocusRequest: @escaping (UInt64) -> Bool,
        onNext: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onFieldDidFocus: @escaping () -> Void
    ) {
        self.panelId = panelId
        self.searchState = searchState
        self.focusRequestGeneration = focusRequestGeneration
        self.canApplyFocusRequest = canApplyFocusRequest
        self.onNext = onNext
        self.onPrevious = onPrevious
        self.onClose = onClose
        self.onFieldDidFocus = onFieldDidFocus
    }

    /// Returns whether this configuration is equivalent to `other` for mount
    /// reuse, comparing only the value and identity fields that affect what the
    /// overlay renders. The closures are ignored: a difference in callbacks does
    /// not require remounting the overlay. ``searchState`` is compared by
    /// reference identity (`===`) because it is the same observable object that
    /// the overlay binds to; only swapping in a different state object matters.
    /// - Parameter other: The configuration to compare against.
    /// - Returns: `true` when both configurations target the same panel, the same
    ///   ``searchState`` instance, and the same focus-request generation.
    @MainActor
    public func isEquivalent(to other: BrowserPortalSearchOverlayConfiguration) -> Bool {
        panelId == other.panelId &&
            searchState === other.searchState &&
            focusRequestGeneration == other.focusRequestGeneration
    }
}
