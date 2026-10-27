import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// A zero-size subview of an agent pane that puts the pane in the visibility tree (``ViewVisibility``):
/// its node sits under its window's node, which follows occlusion, minimizing, other Spaces and app
/// hide once per window (``WindowVisibilitySource``), and AppKit's hide and unhide of the pane or an
/// ancestor set its own state. The pane's ``AgentPaneFramePacer`` reads ``isSeen`` (O(1), no view
/// walk) and hears each flip (``onChange``), then delivers the frames it held while nobody could see
/// the pane. The pane keeps no occlusion observer of its own. Kept off ``AgentPaneView``, whose type is
/// at its size limit.
@MainActor final class AgentPaneVisibilityProbe: NSView {
    /// Runs after each flip of the pane's node, once the whole tree has its new state.
    var onChange: (@MainActor () -> Void)?
    private let visibility = ViewVisibility("agentPane.transport")
    private var flips: VisibilitySubscription?
    /// The pane's node in the visibility tree.
    private var node: VisibilityNode { visibility.node }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        flips = node.subscribe(owner: "AgentPaneVisibilityProbe") { [weak self] _ in self?.onChange?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Whether a person can see the pane: in a window that is on screen, with no hidden view above it.
    var isSeen: Bool { node.isVisible }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.place(in: window)
    }

    override func viewDidHide() {
        super.viewDidHide()
        node.set(.hidden)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        node.set(.visible)
    }
}
