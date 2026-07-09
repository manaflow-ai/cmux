public import Foundation

/// One resolved remote-PTY command target: the workspace whose persistent-PTY
/// controller a `workspace.remote.pty_*` command operates on, plus the
/// pre-encoded handle refs ``ControlRemotePTYWorker`` echoes into every reply.
///
/// The app conformer (``ControlRemotePTYReading``) resolves this on the main
/// actor (reading the live window/workspace/surface graph), builds the window and
/// workspace handle refs with the app's ref machinery, encodes them as
/// ``JSONValue``, and binds the workspace's controller behind
/// ``ControlRemotePTYControlling`` — so this value is a pure Sendable transfer
/// object the worker shapes onto the wire. A `nil` ``controller`` reproduces the
/// legacy "remote connection is not active" branch (the workspace exists but its
/// remote session is not connected).
///
/// The `windowRef`/`workspaceRef` are stored as ``JSONValue`` (the legacy `v2Ref`
/// result, an `NSNull` or a `{ "kind": …, "id": … }` object) so the worker emits
/// byte-identical `window_ref`/`workspace_ref` values without owning the ref
/// vocabulary.
public struct ControlRemotePTYTarget: Sendable {
    /// The workspace's live persistent-PTY controller, or `nil` when the remote
    /// connection is not active (the legacy `target.controller == nil` branch).
    public let controller: (any ControlRemotePTYControlling)?

    /// The owning window's UUID, or `nil` when unresolved (echoed as the
    /// `window_id` payload key via `v2OrNull`).
    public let windowID: UUID?

    /// The owning window's handle ref, pre-encoded (`window_ref`).
    public let windowRef: JSONValue

    /// The workspace's UUID (`workspace_id`).
    public let workspaceID: UUID

    /// The workspace's handle ref, pre-encoded (`workspace_ref`).
    public let workspaceRef: JSONValue

    /// The workspace's display title (`workspace_title`).
    public let workspaceTitle: String

    /// Creates a resolved remote-PTY target.
    ///
    /// - Parameters:
    ///   - controller: The live controller, or `nil` when not connected.
    ///   - windowID: The owning window UUID, if resolved.
    ///   - windowRef: The pre-encoded window handle ref.
    ///   - workspaceID: The workspace UUID.
    ///   - workspaceRef: The pre-encoded workspace handle ref.
    ///   - workspaceTitle: The workspace display title.
    public init(
        controller: (any ControlRemotePTYControlling)?,
        windowID: UUID?,
        windowRef: JSONValue,
        workspaceID: UUID,
        workspaceRef: JSONValue,
        workspaceTitle: String
    ) {
        self.controller = controller
        self.windowID = windowID
        self.windowRef = windowRef
        self.workspaceID = workspaceID
        self.workspaceRef = workspaceRef
        self.workspaceTitle = workspaceTitle
    }
}

/// The outcome of resolving a remote-PTY command target: either a ``target`` or a
/// terminal ``error`` envelope, mirroring the legacy
/// `(target: RemotePTYSocketTarget?, error: V2CallResult?)` tuple.
///
/// The app conformer returns this from the resolve members; the worker forwards
/// the error verbatim when present, otherwise operates on the target.
public struct ControlRemotePTYTargetResolution: Sendable {
    /// The resolved target, or `nil` when ``error`` is set or no workspace
    /// matched (the legacy `not_found` fallback the worker renders).
    public let target: ControlRemotePTYTarget?

    /// A terminal error to return verbatim (the legacy resolver's
    /// `invalid_params` / `not_found` envelopes), or `nil` on success.
    public let error: ControlCallResult?

    /// Creates a resolution outcome.
    ///
    /// - Parameters:
    ///   - target: The resolved target, if any.
    ///   - error: The terminal error, if any.
    public init(target: ControlRemotePTYTarget?, error: ControlCallResult?) {
        self.target = target
        self.error = error
    }
}