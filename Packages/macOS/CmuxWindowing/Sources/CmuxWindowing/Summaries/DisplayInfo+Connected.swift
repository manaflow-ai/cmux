public import AppKit

extension DisplayInfo {
    /// All currently-connected displays, in `NSScreen.screens` order.
    ///
    /// Faithful lift of `AppDelegate.availableDisplays()`: each attached screen
    /// becomes a ``DisplayInfo`` carrying its localized name, zero-based index,
    /// CoreGraphics display id (via ``NSScreen/cmuxDisplayID``), main-display
    /// flag, and global frame. `isMain` is true only when this screen's display
    /// id resolves and equals `NSScreen.main`'s. Reads main-actor `NSScreen`
    /// state, so it is `@MainActor`.
    @MainActor
    public static func connectedDisplays() -> [DisplayInfo] {
        let mainID = NSScreen.main?.cmuxDisplayID
        return NSScreen.screens.enumerated().map { index, screen in
            let displayID = screen.cmuxDisplayID
            return DisplayInfo(
                name: screen.localizedName,
                index: index,
                displayID: displayID,
                isMain: displayID != nil && displayID == mainID,
                frame: screen.frame
            )
        }
    }
}
