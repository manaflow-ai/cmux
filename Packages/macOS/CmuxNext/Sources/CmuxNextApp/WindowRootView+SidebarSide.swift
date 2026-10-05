import AppKit
import CmuxNextDesign
import CmuxNextSidebar
import Observation

// `sidebar.side` and `sidebar.spacesPosition` (R109): the root pins the
// sidebar to the chosen edge, the content and title beside it, and passes
// the spaces position to the sidebar.
extension WindowRootView {
    static func sidePins(sidebar: NSView, content: NSView, title: NSView, in root: NSView) -> [SidebarSide: [NSLayoutConstraint]] {
        // Below required, so the title yields to the traffic-light inset.
        func follow(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
            constraint.priority = .required - 1
            return constraint
        }
        return [
            .left: [sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                    content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                    content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                    follow(title.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)),
                    title.trailingAnchor.constraint(equalTo: root.trailingAnchor)],
            .right: [sidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                     content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                     content.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                     follow(title.leadingAnchor.constraint(equalTo: root.leadingAnchor)),
                     title.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor)],
        ]
    }

    /// Swaps the pins to `sidebarSide` without animating. The layout may
    /// only move (same size), which runs no layout pass of its own, so it
    /// is laid out here: pane rings and overlay rects follow, and strips
    /// under the traffic lights re-check themselves (`syncOverlay`).
    func applySidebarSide() {
        for (side, constraints) in sidePins where side != sidebarSide { NSLayoutConstraint.deactivate(constraints) }
        NSLayoutConstraint.activate(sidePins[sidebarSide] ?? [])
        sidebar.side = sidebarSide
        layoutSubtreeIfNeeded()
        content?.needsLayout = true
        content?.layoutSubtreeIfNeeded()
    }

    /// Follows the two settings from `DesignSettings` (init reads the
    /// first values; the first emission repeats them and changes nothing).
    func observePlacement() -> Task<Void, Never> {
        Task { [weak self] in
            for await (side, spaces) in Observations({ (DesignSettings.shared.sidebarSide, DesignSettings.shared.spacesPosition) }) {
                self?.sidebarSide = side
                self?.sidebar.sidebarView.spacesPosition = spaces
            }
        }
    }
}
