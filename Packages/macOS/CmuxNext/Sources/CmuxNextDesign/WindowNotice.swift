/// One of a window's notices that ``WindowNotices`` observes once per window.
public enum WindowNotice: Hashable, Sendable {
    /// The window became the main window (`NSWindow.didBecomeMainNotification`).
    case becameMain
    /// The window stopped being the main window (`NSWindow.didResignMainNotification`).
    case resignedMain
    /// The window's occlusion state changed (`NSWindow.didChangeOcclusionStateNotification`); read
    /// `occlusionState` for the new state.
    case occlusionChanged
}
