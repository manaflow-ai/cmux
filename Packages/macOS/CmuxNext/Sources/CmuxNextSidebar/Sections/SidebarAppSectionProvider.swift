public import AppKit
public import CmuxNextDesign

/// Draws the sections that apps contribute (`SectionContent.app`,
/// plans/cmux-next/sidebar-sections.md; the app platform supplies it). One
/// provider per sidebar, so each window mounts its own views. A section whose
/// provider returns no view draws nothing (an app that is not presented).
@MainActor
public protocol SidebarAppSectionProvider: AnyObject {
    /// The header title, or nil to draw none.
    func title(for contribution: String) -> String?
    /// The section's content view, created once and kept while it shows.
    func makeView(for contribution: String) -> NSView?
    /// The content height at `width`; 0 before the view has content.
    func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat
    /// Called by the provider when a section's content height may have changed.
    var onContentChange: (() -> Void)? { get set }
    /// The section left the layout (removed, or its app hidden): drop its
    /// view and end what feeds it. A collapsed or moved section is not released.
    func release(_ contribution: String)
    /// This window's own workspace list (`cmux.sidebar/1`, opt-in), drawn in place of the built-in
    /// list while it is drawn; nil keeps the built-in list.
    var workspaceList: (any SidebarListReplacement)? { get }
}

public extension SidebarAppSectionProvider {
    func release(_ contribution: String) {}
    var workspaceList: (any SidebarListReplacement)? { nil }
}
