public import CmuxRemoteDesktop

/// One session's entry in the indicator.
public protocol RemoteDesktopIndicatorHandle: Sendable {
    /// Yields once when the person at the Mac presses Stop (or Stop All).
    var stopRequests: AsyncStream<Void> { get }
    func update(mode: DesktopMode) async
    /// Removes the entry; the session ended.
    func end() async
}
