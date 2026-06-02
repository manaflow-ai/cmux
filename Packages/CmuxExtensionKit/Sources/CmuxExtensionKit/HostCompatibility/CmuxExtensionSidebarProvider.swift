import Foundation

/// A host-side sidebar view that renders cmux workspaces into sidebar sections.
///
/// Conformers describe themselves with a ``CmuxExtensionSidebarProviderDescriptor``
/// and turn a ``CmuxExtensionSidebarSnapshot`` into a
/// ``CmuxExtensionSidebarRenderModel``. The built-in views (Project Worktrees,
/// Attention Queue, Dev Servers, Last Prompt, Super Compact, Browser Stack) all
/// conform to this protocol or one of its refinements.
public protocol CmuxExtensionSidebarProvider: Sendable {
    /// Menu/registry metadata (title, icon, id) for this sidebar view.
    var descriptor: CmuxExtensionSidebarProviderDescriptor { get }

    /// Produces the sidebar contents for the given workspace snapshot.
    ///
    /// This is a protocol *requirement* (not only a protocol-extension default)
    /// on purpose: the host renders providers through an
    /// `any CmuxExtensionSidebarProvider` existential, and a method that lives
    /// solely in a protocol extension would static-dispatch to the extension's
    /// default instead of the conforming type's implementation — silently
    /// yielding an empty sidebar. Declaring it here gives every conformer a
    /// witness-table entry so the call dynamic-dispatches correctly.
    ///
    /// ``CmuxExtensionKit`` still supplies a default that returns no sections, so
    /// providers that render exclusively through
    /// ``CmuxExtensionSidebarContextualProvider/render(snapshot:context:)`` are
    /// not forced to implement this directly.
    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel
}
