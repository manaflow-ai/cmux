import Foundation

/// An image attached to a checklist item, named by an absolute file path
/// (`WorkspaceChecklistAttachment`). The daemon keeps the path, not the file.
public struct WorkspaceChecklistAttachment: Sendable, Hashable, Codable, Identifiable {
    /// The daemon's id (`att_…`); nil for one not sent yet.
    public var id: String?
    /// The absolute path of the image file.
    public var path: String
    /// The name shown for it: the file name unless someone named it.
    public var name: String

    /// Creates an attachment.
    /// - Parameters:
    ///   - id: The daemon's id; nil for a new attachment, which the daemon gives one.
    ///   - path: The absolute path of the image file.
    ///   - name: The name shown; the path's file name when nil.
    public init(id: String? = nil, path: String, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
    }
}
