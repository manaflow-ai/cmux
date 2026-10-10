import Foundation

/// A workspace file returned by Go to File.
public struct GoToFileMatch: Identifiable, Equatable, Sendable {
    public let path: String

    /// Creates a match for a workspace-relative path.
    public init(path: String) { self.path = path }

    /// Uses the relative path as the stable result identifier.
    public var id: String { path }

    /// The final path component shown as the file name.
    public var fileName: String { (path as NSString).lastPathComponent }
}
