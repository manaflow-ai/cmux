public import Foundation

/// One surface (terminal/browser/etc. tab) projected for the custom-sidebar
/// interpreter context, in the order it appears inside its workspace.
///
/// The app builds this by walking a workspace's bonsplit panes; the
/// interpreter data-context builder maps it to the `tabs[i]` value object.
/// Optional fields are `nil` when absent so interpreted `if let` / ternary
/// truthiness behaves; `nil` and empty strings are both treated as absent.
public struct CustomSidebarSurfaceSnapshot: Sendable, Equatable {
    /// The panel identifier, projected to the interpreter `tabs[i].id` string.
    public let panelId: UUID
    /// The surface title (`tabs[i].title`).
    public let title: String
    /// The surface kind (`tabs[i].kind`), e.g. terminal/browser/markdown.
    public let kind: String
    /// Whether this surface is the workspace's focused panel (`tabs[i].focused`).
    public let isFocused: Bool
    /// Whether the surface's panel is pinned (`tabs[i].pinned`).
    public let isPinned: Bool
    /// The surface's working directory, or `nil`/empty when unknown
    /// (`tabs[i].directory`).
    public let directory: String?
    /// The surface's git branch name when known (`tabs[i].branch`).
    public let gitBranch: String?
    /// Whether the surface's git branch has uncommitted changes
    /// (`tabs[i].dirty`); meaningful only when ``gitBranch`` is non-nil.
    public let gitIsDirty: Bool
    /// The surface's listening ports, or empty when none (`tabs[i].ports`).
    public let listeningPorts: [Int]

    /// Creates a surface snapshot from already-resolved leaf values.
    public init(
        panelId: UUID,
        title: String,
        kind: String,
        isFocused: Bool,
        isPinned: Bool,
        directory: String?,
        gitBranch: String?,
        gitIsDirty: Bool,
        listeningPorts: [Int]
    ) {
        self.panelId = panelId
        self.title = title
        self.kind = kind
        self.isFocused = isFocused
        self.isPinned = isPinned
        self.directory = directory
        self.gitBranch = gitBranch
        self.gitIsDirty = gitIsDirty
        self.listeningPorts = listeningPorts
    }
}
