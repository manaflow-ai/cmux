public import Foundation

/// The state needed to resume a remote-daemon terminal session after a reconnect.
public struct TerminalRemoteDaemonResumeState: Codable, Equatable, Sendable {
    /// The remote daemon session identifier to reattach to.
    public var sessionID: String
    /// The attachment identifier issued for this client's connection to the session.
    public var attachmentID: String
    /// The byte offset already read, so the resumed stream continues from the right place.
    public var readOffset: UInt64

    /// Creates a resume state.
    /// - Parameters:
    ///   - sessionID: The remote daemon session identifier.
    ///   - attachmentID: The attachment identifier for this client.
    ///   - readOffset: The byte offset already consumed from the stream.
    public init(sessionID: String, attachmentID: String, readOffset: UInt64) {
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.readOffset = readOffset
    }
}
