public import CmuxBrowserStream
public import CmuxRemoteDesktop

/// One open desktop: its video, input, clipboard and lifecycle. Input
/// reaches it only in control mode while the session gate is open; the
/// session enforces that, the target only injects.
public protocol RemoteDesktopTarget: Sendable {
    /// Current size and name (VNC learns it at ServerInit; `events` reports changes).
    func info() async -> DesktopTargetInfo
    /// Encoded frames, pulled newest-wins; the request size is the view's pixel size.
    var video: any BrowserVideoSource { get }
    /// Where the pointer is drawn.
    var cursor: RemoteDesktopChannelOpened.Cursor { get }
    /// Crops capture to `rect` (target pixels); later frames show that rect.
    func setRegion(_ rect: DesktopRect) async throws
    /// Injects one event (pointer in target pixels, HID key usages, text).
    func apply(_ event: RdInputEvent) async
    func pushClipboard(_ text: String) async
    /// The Mac's (or VNC server's last) clipboard text, read now.
    func readClipboard() async -> String?
    /// Answers `RemoteDesktopTargetEvent.authRequired` (VNC only).
    func authenticate(password: String) async
    /// Lifecycle events. One consumer.
    func events() async -> AsyncStream<RemoteDesktopTargetEvent>
    func close() async
}
