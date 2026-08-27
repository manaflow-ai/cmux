public import Foundation

/// Summary row for one saved layout.
public struct ControlSavedLayoutSummary: Sendable {
    /// The saved layout name.
    public let name: String
    /// The optional saved layout description.
    public let description: String?
    /// The number of panes in the saved layout tree.
    public let paneCount: Int
    /// The number of surfaces in the saved layout tree.
    public let surfaceCount: Int

    /// Creates a saved-layout summary row.
    public init(name: String, description: String?, paneCount: Int, surfaceCount: Int) {
        self.name = name
        self.description = description
        self.paneCount = paneCount
        self.surfaceCount = surfaceCount
    }
}

/// The result of `layout.save`.
public enum ControlLayoutSaveResolution: Sendable {
    /// The target workspace could not be found.
    case workspaceNotFound
    /// A layout already exists with the requested name.
    case alreadyExists
    /// The store file could not be decoded.
    case corruptFile(String)
    /// The layout was saved.
    case saved(name: String, path: String, unsupportedSurfaceCount: Int)
    /// An unexpected store error occurred.
    case failed(String)
}

/// The result of `layout.list`.
public enum ControlLayoutListResolution: Sendable {
    /// The store file could not be decoded.
    case corruptFile(String)
    /// Layouts were read.
    case resolved([ControlSavedLayoutSummary])
    /// An unexpected store error occurred.
    case failed(String)
}

/// The result of `layout.get`.
public enum ControlLayoutGetResolution: Sendable {
    /// No layout exists with the requested name.
    case notFound
    /// The store file could not be decoded.
    case corruptFile(String)
    /// The full saved-layout JSON object.
    case resolved(JSONValue)
    /// An unexpected store error occurred.
    case failed(String)
}

/// The result of `layout.open`.
public enum ControlLayoutOpenResolution: Sendable {
    /// No layout exists with the requested name.
    case layoutNotFound
    /// No `TabManager` could be resolved for the request.
    case tabManagerUnavailable
    /// The store file could not be decoded.
    case corruptFile(String)
    /// The workspace was opened.
    case opened(workspaceID: UUID)
    /// An unexpected store error occurred.
    case failed(String)
}

/// The result of `layout.delete`.
public enum ControlLayoutDeleteResolution: Sendable {
    /// No layout exists with the requested name.
    case notFound
    /// The store file could not be decoded.
    case corruptFile(String)
    /// The layout was deleted.
    case deleted
    /// An unexpected store error occurred.
    case failed(String)
}

/// The saved-layout-domain slice of the control-command seam.
@MainActor
public protocol ControlLayoutContext: AnyObject {
    /// Saves a target workspace's current layout.
    func controlLayoutSave(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        name: String,
        description: String?,
        overwrite: Bool
    ) -> ControlLayoutSaveResolution

    /// Lists all saved layouts.
    func controlLayoutList() -> ControlLayoutListResolution

    /// Reads one saved layout as a JSON object.
    func controlLayoutGet(name: String) -> ControlLayoutGetResolution

    /// Opens a new workspace from one saved layout.
    func controlLayoutOpen(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        focusRequested: Bool
    ) -> ControlLayoutOpenResolution

    /// Deletes one saved layout.
    func controlLayoutDelete(name: String) -> ControlLayoutDeleteResolution
}
