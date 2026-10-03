public import AppKit

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
}
