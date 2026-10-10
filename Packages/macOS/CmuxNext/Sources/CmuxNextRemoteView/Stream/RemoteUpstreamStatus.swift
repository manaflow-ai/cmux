import Foundation

/// The upstream media of a session as the transport reports it: whether the
/// host offers it (welcome lists `up_media` and `stream.open`), the kinds
/// waiting for the host's answer and the kinds that hold consent now.
public nonisolated struct RemoteUpstreamStatus: Sendable, Hashable {
    public var offered: Bool
    public var requested: Set<RemoteUpstreamKind>
    public var active: Set<RemoteUpstreamKind>

    public init(offered: Bool = false, requested: Set<RemoteUpstreamKind> = [], active: Set<RemoteUpstreamKind> = []) {
        self.offered = offered
        self.requested = requested
        self.active = active
    }
}

/// The pane's upstream commands to its transport. The transport is the one
/// place that enforces the consent contract (`RemoteUpstreamConsent`); the
/// pane calls `requestUpstream` only from the user's explicit per-kind
/// action, after that action asked macOS for the permission.
public nonisolated protocol RemoteUpstreamControl: AnyObject, Sendable {
    /// Opens the kind's stream; `permissionGranted` false refuses it.
    func requestUpstream(_ kind: RemoteUpstreamKind, permissionGranted: Bool)
    /// Revokes the kind's consent at once and closes its stream.
    func stopUpstream(_ kind: RemoteUpstreamKind)
    /// Revokes every kind (the tab closed or hid).
    func stopAllUpstreams()
}
