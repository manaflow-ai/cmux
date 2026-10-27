import AppKit
public import CmuxHomeCore

/// cmux (p14-energy-115): the list's typing bubbles pulse through the host's ``LoopHost``, so no
/// pulse runs while the list's window is hidden or occluded. The names below let the vendored
/// files spell the host without importing CmuxHomeCore, whose ConversationID and
/// ConversationSummary are not this module's.
typealias SidebarLoopHost = LoopHost

/// The host of a list no host gave one (tests): each pulse runs as attached.
typealias SidebarStandaloneLoops = StandaloneLoopHost

extension CmuxSidebarView {
    /// Where the typing bubbles pulse: the host's ``LoopHost``. A host that is a view goes in this
    /// view, so it follows this view's window and hidden state (cmux-next's `HomeLoopProbe`: no pulse
    /// while the window is hidden or occluded). Set it before the first ``show(_:pinned:)``; a bubble
    /// already pulsing keeps the host it started with.
    public var loops: any LoopHost {
        get { controller.loops }
        set {
            (controller.loops as? NSView)?.removeFromSuperview()
            controller.loops = newValue
            if let probe = newValue as? NSView { addSubview(probe) }
        }
    }
}
