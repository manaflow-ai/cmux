import Foundation

/// A Claude session discovered for a workspace, used to materialize/refresh
/// session folders. Produced by the app from `SessionIndexStore` and handed to
/// ``NotesTreeStorage/syncSessionFolders(inRoot:descriptors:)``.
struct NotesSessionDescriptor: Codable, Equatable, Sendable {
    var agent: String
    var sessionId: String
    var title: String
    var cwd: String
    /// Session last-modified time (Unix seconds), for the relative timestamp.
    var modified: TimeInterval
}
