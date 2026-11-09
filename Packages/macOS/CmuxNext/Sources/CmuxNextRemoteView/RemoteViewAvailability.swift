/// Whether this build exposes the remote desktop pane. Phase 1 has a trust
/// gap: the host cannot yet verify the viewer's hello claims (the overlay
/// link token does not authenticate them), so the pane's development hosts
/// (the mock desktop, a loopback `cmux-rd host`, an RFB server) exist only in
/// Debug builds; Release and NIGHTLY refuse them. The App checks this before
/// it offers such a `remote_view` tab.
///
/// A Cloud machine's desktop on its `cmux-rd` host (`cloudRd`) is the one
/// exception, in every build: the stream rides the owner's Native link as
/// service `desktop`, which the machine's root receiver admits with the link's
/// own one-time owner token (as it admits `daemon` and `ssh`); the host then
/// takes only that receiver's connection, so no hello claim or token admits a
/// viewer there.
public struct RemoteViewAvailability {
    public init() {}
    #if DEBUG
    public let isAvailable = true
    #else
    public let isAvailable = false
    #endif
    /// A Cloud machine's `cmux-rd` desktop over its Native link: every build.
    public let isCloudRdAvailable = true
}
