import AppKit
import CmuxNextDesign
import CmuxNextUpdater

/// Restart to Update (cx-ncc.45 S1): at the click every window becomes
/// transparent and click-through, so the old app leaves the screen in the
/// next frame while it saves and exits; the relaunched app opens the same
/// windows from the daemon. The windows stay alive: the quit still saves
/// their launch images and frames from them. An install that fails brings
/// them back. With unsaved documents nothing hides: the quit asks about
/// them on screen (decision D2).
@MainActor
final class UpdateWindowHandoff {
    private struct Hidden {
        weak var window: NSWindow?
        var alpha: CGFloat
        var ignoresMouse: Bool
    }

    private var hidden: [Hidden] = []
    private let unsaved: QuitUnsavedRegistry

    init(unsaved: QuitUnsavedRegistry = .shared) {
        self.unsaved = unsaved
    }

    /// Hides every visible window; false when it did not (unsaved documents).
    @discardableResult
    func hide() -> Bool {
        guard hidden.isEmpty, unsaved.unsaved().isEmpty else { return false }
        hidden = NSApp.windows.filter(\.isVisible).map { Hidden(window: $0, alpha: $0.alphaValue, ignoresMouse: $0.ignoresMouseEvents) }
        for entry in hidden {
            entry.window?.alphaValue = 0
            entry.window?.ignoresMouseEvents = true
        }
        #if DEBUG
        UpdateHarness.mark("windows_hidden.\(hidden.count)")
        #endif
        return true
    }

    /// Brings the hidden windows back as they were.
    func restore() {
        for entry in hidden {
            entry.window?.alphaValue = entry.alpha
            entry.window?.ignoresMouseEvents = entry.ignoresMouse
        }
        hidden = []
    }
}
