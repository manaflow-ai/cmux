public import AppKit

/// Files one ``StatusIndicatorResyncClient`` under the window it is in and whether it shows there,
/// so a resync reaches the indicators of the window whose state changed, and only the shown ones.
///
/// The host owns one placement and calls ``update(_:in:shown:)`` whenever its window or its
/// visibility may have changed (`viewDidMoveToWindow`, `viewDidHide`, `viewDidUnhide`, or its own
/// shown-in-window sync). A host that shows again after a resync ran in its window while it was
/// hidden resyncs once, at once; one that moves into a window starts current (its own move
/// handling draws it).
///
/// ```swift
/// private let placement = StatusIndicatorPlacement()
///
/// override func viewDidUnhide() {
///     super.viewDidUnhide()
///     placement.update(self, in: window, shown: !isHiddenOrHasHiddenAncestor)
/// }
/// ```
@MainActor
public final class StatusIndicatorPlacement {
    /// The indicators of the window the host is in (nil: no window, or that window is gone).
    private weak var windowSet: WindowIndicatorResync?
    private var isShown = false
    /// The window's resync generation when the host entered it or last hid in it.
    private var seen: UInt64 = 0

    /// A placement in no window.
    public init() {}

    /// Files `client` under `window` (nil: in no window), shown or hidden there.
    ///
    /// - Parameters:
    ///   - client: The host that owns this placement.
    ///   - window: The window the host is in now.
    ///   - shown: Whether the host shows in it now (no hidden flag of its own or an ancestor's).
    public func update(_ client: any StatusIndicatorResyncClient, in window: NSWindow?, shown: Bool) {
        // A window in deallocation is no window: its tracker must not be made or stored weakly now.
        let target = window.flatMap { $0.isBeingDeallocated ? nil : WindowKeyFamily.of($0).indicators }
        if target !== windowSet {
            windowSet?.leave(client)
            windowSet = target
            isShown = false
            guard let target else { return }
            seen = target.generation
            target.enter(client)
        }
        guard let windowSet, shown != isShown else { return }
        isShown = shown
        if shown {
            windowSet.show(client)
            // A resync ran in this window while the host was hidden.
            if windowSet.generation != seen { client.statusIndicatorResync() }
        } else {
            windowSet.hide(client)
            seen = windowSet.generation
        }
    }
}
