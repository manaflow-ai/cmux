// cmux: what the host app gives the conversation list. Not a vendored file.
import AppKit

/// The host's hooks for the conversation list, set once before its first frame (``CmuxSidebarView/host``): its
/// movement gate and its tooltip. Each default is the package's own behaviour, for a host that sets none.
public struct CmuxSidebarHost {
    /// The host's motion gate for movement (cmux-next: `Motion.animatesMovement`, so the animation speed `off` and the
    /// motion settings also apply); nil: only Reduce Motion decides. Read when a movement starts.
    public var movementGate: (@MainActor () -> Bool)?

    /// How a list control shows its tooltip (``AppKit/NSView/setSidebarToolTip(_:)``); nil text: none. cmux-next
    /// installs its one themed tooltip (`NSView.themedToolTip`; Lawrence 2026-11-20); the default is AppKit's.
    public var showToolTip: @MainActor (_ view: NSView, _ text: String?) -> Void = { view, text in
        view.toolTip = text // tooltip-native-allow: the package's fallback for a host without its own tooltip
    }

    /// The package's own behaviour.
    public init() {}
}
