import Foundation

/// The per-surface values a ``TerminalBadgeTemplate`` substitutes into its
/// placeholders when rendering a badge string.
///
/// The host (the terminal surface) fills this in from the surface's owning
/// workspace and its position within the pane, then hands it to
/// ``TerminalBadgeTemplate/render(context:)``. All fields are optional because
/// a surface may not yet be attached to a workspace; an absent value renders
/// as the empty string.
///
/// ```swift
/// let context = TerminalBadgeContext(
///     workspace: "feature/login",
///     tab: "claude",
///     tabIndex: 2,
///     workspaceIndex: 1
/// )
/// let text = TerminalBadgeTemplate(rawValue: "{workspace} · {tab}").render(context: context)
/// // text == "feature/login · claude"
/// ```
public struct TerminalBadgeContext: Sendable, Equatable {
    /// The owning workspace's title, or `nil` when unknown.
    public var workspace: String?
    /// The surface/tab title, or `nil` when unknown.
    public var tab: String?
    /// The surface's 1-based position within its pane, or `nil` when unknown.
    public var tabIndex: Int?
    /// The workspace's 1-based position in the sidebar, or `nil` when unknown.
    public var workspaceIndex: Int?

    /// Creates a badge substitution context.
    ///
    /// - Parameters:
    ///   - workspace: The owning workspace's title.
    ///   - tab: The surface/tab title.
    ///   - tabIndex: The surface's 1-based position within its pane.
    ///   - workspaceIndex: The workspace's 1-based position in the sidebar.
    public init(
        workspace: String? = nil,
        tab: String? = nil,
        tabIndex: Int? = nil,
        workspaceIndex: Int? = nil
    ) {
        self.workspace = workspace
        self.tab = tab
        self.tabIndex = tabIndex
        self.workspaceIndex = workspaceIndex
    }
}
