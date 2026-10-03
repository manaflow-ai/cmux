/// Whether this build exposes the remote desktop pane. Phase 1 has a trust
/// gap: the host cannot yet verify the viewer's hello claims (the overlay
/// link token does not authenticate them), so the pane and its mock host
/// exist only in Debug builds. Release and NIGHTLY compile them out; the App
/// checks this before it offers a `remote_view` tab.
public nonisolated enum RemoteViewAvailability {
    #if DEBUG
    public static let isAvailable = true
    #else
    public static let isAvailable = false
    #endif
}
