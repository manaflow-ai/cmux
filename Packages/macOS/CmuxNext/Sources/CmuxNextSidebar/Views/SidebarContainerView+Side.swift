import AppKit
import CmuxNextDesign

// `sidebar.side` (R109): the panel pins to the edge facing the content, so
// a hiding sidebar slides out past the window edge, and the resize handle
// sits on that inner edge.
extension SidebarContainerView {
    static func pins(panel: NSView, clip: NSView, handle: NSView, in container: NSView) -> [SidebarSide: [NSLayoutConstraint]] {
        let reach = Metrics.dividerHitWidth / 2
        return [
            .left: [panel.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                    handle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: reach)],
            .right: [panel.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                     handle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: -reach)],
        ]
    }

    /// Swaps the pins to `side` without animating.
    func applySide() {
        for (pinSide, constraints) in sidePins where pinSide != side { NSLayoutConstraint.deactivate(constraints) }
        NSLayoutConstraint.activate(sidePins[side] ?? [])
        needsLayout = true
    }
}
