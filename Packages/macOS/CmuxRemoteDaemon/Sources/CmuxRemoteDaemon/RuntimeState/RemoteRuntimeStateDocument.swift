public import Foundation

/// One authoritative workspace-state revision returned by `cmuxd-remote`.
///
/// The daemon treats ``state`` as an opaque JSON object so clients can evolve
/// their workspace schema independently of the transport protocol. The
/// ``ptySessions`` manifest is daemon-authored and describes the live PTYs
/// whose capped scrollback is replayed when the workspace snapshot reattaches.
public struct RemoteRuntimeStateDocument: Sendable, Equatable {
    /// The runtime-state wire protocol implemented by this client.
    public static let protocolVersion = 1

    /// Client-owned schema version for the JSON object in ``state``.
    public let schemaVersion: Int
    /// Monotonically increasing daemon-owned revision.
    public let revision: UInt64
    /// Server update time in Unix milliseconds.
    public let updatedAtUnixMilliseconds: Int64
    /// Opaque client workspace snapshot encoded as a JSON object.
    public let state: Data
    /// Daemon-authored live PTY manifest encoded as a JSON array.
    public let ptySessions: Data

    /// Creates a decoded runtime-state document.
    ///
    /// - Parameters:
    ///   - schemaVersion: Client-owned schema version for `state`.
    ///   - revision: Monotonic server revision.
    ///   - updatedAtUnixMilliseconds: Server update time in Unix milliseconds.
    ///   - state: Workspace snapshot encoded as a JSON object.
    ///   - ptySessions: Live PTY manifest encoded as a JSON array.
    public init(
        schemaVersion: Int,
        revision: UInt64,
        updatedAtUnixMilliseconds: Int64,
        state: Data,
        ptySessions: Data
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.updatedAtUnixMilliseconds = updatedAtUnixMilliseconds
        self.state = state
        self.ptySessions = ptySessions
    }
}
