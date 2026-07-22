public import Foundation

/// The immutable app identity against which command-palette actions were
/// enumerated.
///
/// `palette.list` returns this value and `palette.run` accepts it verbatim.
/// Echoing it prevents a later focus or selection change from retargeting the
/// chosen action.
public struct ControlCommandPaletteTarget: Sendable, Equatable {
    /// The window that owns the live command-palette registry.
    public let windowID: UUID
    /// The workspace selected when the registry was enumerated, if one exists.
    public let workspaceID: UUID?
    /// The panel selected within ``workspaceID``, if one exists.
    public let panelID: UUID?

    /// Creates an immutable command-palette target.
    ///
    /// - Parameters:
    ///   - windowID: The window that owns the action registry.
    ///   - workspaceID: The resolved workspace, if one existed at list time.
    ///   - panelID: The resolved panel, if one existed at list time.
    public init(windowID: UUID, workspaceID: UUID?, panelID: UUID?) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.panelID = panelID
    }
}
