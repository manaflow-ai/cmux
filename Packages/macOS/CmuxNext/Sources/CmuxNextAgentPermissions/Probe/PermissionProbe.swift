/// Reads macOS grants without prompting (the TCC seam).
///
/// The App answers it from the system (`SystemPermissionProbe`: the helper's
/// grants through Computer Use Setup, a protected-file read for Full Disk
/// Access, `AVCaptureDevice` for camera and microphone);
/// ``MockPermissionProbe`` stands in for tests and the gallery.
@MainActor
public protocol PermissionProbe: AnyObject {
    /// The grant now. Never shows a macOS prompt.
    func status(_ kind: PermissionKind, target: String?) async -> PermissionStatus
    /// One element each time a grant may have changed (the app became
    /// active, macOS posted a trust change, the helper answered). The stream
    /// ends when the consumer cancels. Nothing polls.
    func changes() -> AsyncStream<Void>
}
