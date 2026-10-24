/// An indicator host that checks itself again when its window's state changes: its window became
/// main, or the app came back (to the front, unhidden, after sleep) while the window is on screen,
/// or the window showed after it missed that. It files itself under the window it is in through a
/// ``StatusIndicatorPlacement``; only shown hosts are called, and a hidden one catches up when it
/// shows.
@MainActor
public protocol StatusIndicatorResyncClient: AnyObject {
    /// Checks the indicator against what it should show now (its window's visibility, a loop it
    /// lacks). Called only while the host shows in a window.
    func statusIndicatorResync()
}
