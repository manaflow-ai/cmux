public import AppKit
public import CmuxNextDesignTokens

// `sidebar.side` (R109): the root pins the sidebar to the chosen edge and the
// content and title beside it. Moved out of CmuxNextApp (SW14 app-size cap).
extension SidebarSide {
    /// Each side's edge constraints for the sidebar, the content host and
    /// the titlebar in `root`; the root activates one side's set.
    ///
    /// The content sits the main pane's gutter from the sidebar and never
    /// nearer the window edge than the gutter; the root applies the gutter
    /// as both constants, so a hiding sidebar leaves the gutter at the
    /// edge. The title's pin to the sidebar stays
    /// below required, so it yields to the traffic-light inset.
    @MainActor
    public static func pins(sidebar: NSView, content: NSView, title: NSView, in root: NSView) -> [SidebarSide: [NSLayoutConstraint]] {
        func priority(_ constraint: NSLayoutConstraint, _ value: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
            constraint.priority = value
            return constraint
        }
        return [
            .left: [sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                    priority(content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), .required - 2),
                    content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor),
                    content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                    priority(title.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), .required - 1),
                    title.trailingAnchor.constraint(equalTo: root.trailingAnchor)],
            .right: [sidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                     content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                     priority(content.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor), .required - 2),
                     content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
                     priority(title.leadingAnchor.constraint(equalTo: root.leadingAnchor), .required - 1),
                     title.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor)],
        ]
    }
}
