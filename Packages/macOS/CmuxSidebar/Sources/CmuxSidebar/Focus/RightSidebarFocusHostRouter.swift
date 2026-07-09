public import AppKit

/// Owns the right sidebar's per-mode keyboard-focus hosts and routes
/// responder-ownership, endpoint-focus, and mode-lookup queries to them.
///
/// `MainWindowFocusController` holds one instance and registers each host view
/// weakly through this router: the `RightSidebarHostFocusing` fallback host, the
/// two `FileExplorerFocusHosting` endpoints (`.files` outline and `.find`
/// search), the `FeedFocusHosting` endpoint, and the `DockFocusHosting` endpoint.
/// The router carries no focus *intent* or focus-state-machine state; the
/// controller keeps that live wiring and asks the router only the stateless
/// host-routing questions: who owns this responder, focus this mode's endpoint,
/// focus the fallback host, and which mode owns this responder. Every reference is
/// `weak`, so a torn-down host view deregisters itself by deallocating.
@MainActor
public final class RightSidebarFocusHostRouter {
    /// The fallback host that accepts first responder when no per-mode endpoint
    /// claims focus.
    public weak var rightSidebarHost: (any RightSidebarHostFocusing)?
    /// The `.files` (outline) file-explorer endpoint.
    public weak var fileExplorerHost: (any FileExplorerFocusHosting)?
    /// The `.find` (search) file-explorer endpoint.
    public weak var fileSearchHost: (any FileExplorerFocusHosting)?
    /// The `.feed` endpoint.
    public weak var feedHost: (any FeedFocusHosting)?
    /// The `.dock` endpoint.
    public weak var dockHost: (any DockFocusHosting)?

    /// The most recently published feed focus snapshot, used to dedup redundant
    /// pushes to the feed host.
    private var lastPublishedFeedFocusSnapshot = FeedFocusSnapshot()

    /// Creates an empty router; hosts register themselves once the owning
    /// window's sidebar views attach.
    public init() {}

    /// Publishes `snapshot` to the feed host, skipping the push when it equals
    /// the last published snapshot unless `force` is set. Stores the published
    /// snapshot for future dedup comparisons.
    public func publishFeedFocusSnapshot(_ snapshot: FeedFocusSnapshot, force: Bool = false) {
        guard force || snapshot != lastPublishedFeedFocusSnapshot else { return }
        lastPublishedFeedFocusSnapshot = snapshot
        feedHost?.applyFocusSnapshotFromController(snapshot)
    }

    /// Whether `responder` belongs to any registered right-sidebar host: the
    /// fallback host's own identity, a `FeedKeyboardFocusResponder` marker, or a
    /// per-mode endpoint's responder ownership.
    public func ownsRightSidebarFocus(_ responder: NSResponder) -> Bool {
        if let host = rightSidebarHost, responder === host {
            return true
        }
        if responder is any FeedKeyboardFocusResponder {
            return true
        }
        if fileExplorerHost?.ownsKeyboardFocus(responder) == true ||
            fileSearchHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        if feedHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        if dockHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        return false
    }

    /// Moves keyboard focus to `mode`'s endpoint, optionally targeting its first
    /// item. Returns whether the endpoint took focus.
    public func focusRightSidebarEndpoint(
        mode: RightSidebarMode,
        target: RightSidebarFocusTarget
    ) -> Bool {
        switch mode {
        case .files:
            return fileExplorerHost?.focusOutline() == true
        case .find:
            return fileSearchHost?.focusSearchField() == true
        case .sessions:
            return false
        case .feed:
            if target == .firstItem {
                feedHost?.focusFirstItemFromCoordinator()
            }
            return feedHost?.focusHostFromCoordinator() == true
        case .dock:
            if target == .firstItem {
                dockHost?.focusFirstItemFromCoordinator()
            }
            return dockHost?.focusHostFromCoordinator() == true
        case .customSidebar:
            return false
        }
    }

    /// Makes the fallback right-sidebar host first responder in `window`. Returns
    /// whether focus was taken; `false` when either `window` or the host is absent.
    public func focusFallbackRightSidebarHost(window: NSWindow?) -> Bool {
        guard let window,
              let host = rightSidebarHost else {
            return false
        }
        return window.makeFirstResponder(host.focusResponder)
    }

    /// Which right-sidebar mode owns `responder`, or `nil` if none does.
    /// `fallbackMode` is returned when `responder` is the fallback host itself; the
    /// controller supplies the file-explorer state's mode or the remembered mode.
    public func rightSidebarModeOwning(
        _ responder: NSResponder,
        fallbackMode: RightSidebarMode?
    ) -> RightSidebarMode? {
        if let host = rightSidebarHost, responder === host {
            return fallbackMode
        }
        if fileExplorerHost?.ownsKeyboardFocus(responder) == true {
            return .files
        }
        if fileSearchHost?.ownsKeyboardFocus(responder) == true {
            return .find
        }
        if feedHost?.ownsKeyboardFocus(responder) == true || responder is any FeedKeyboardFocusResponder {
            return .feed
        }
        if dockHost?.ownsKeyboardFocus(responder) == true {
            return .dock
        }
        return nil
    }
}
