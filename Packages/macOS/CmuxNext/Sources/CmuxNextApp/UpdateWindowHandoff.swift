import AppKit
import CmuxNextDesign
import CmuxNextUpdater

/// Restart to Update (cx-ncc.45 S1): what the old windows do at the click.
/// ``mode`` is the one switch (hq-a3 rule 2026-10-10: hide when the click
/// to the relaunched window's first frame takes 300 ms or less, else keep
/// the windows on screen, frozen, with the update card's Installing state
/// as the mark, so the screen never looks like a crash).
///
/// Hidden windows are transparent and click-through: the old app leaves the
/// screen in the next frame while it saves and exits, and the relaunched app
/// opens the same windows from the daemon. Frozen windows stay as they are
/// and take no clicks. Either way the windows stay alive (the quit still
/// saves their launch images and frames), and an install that fails brings
/// them back. With unsaved documents nothing changes: the quit asks about
/// them on screen (decision D2).
@MainActor
final class UpdateWindowHandoff {
    private struct Hidden {
        weak var window: NSWindow?
        var alpha: CGFloat
        var ignoresMouse: Bool
    }

    enum Mode {
        case hide, freeze
    }

    /// The one switch between the two forms.
    static let mode: Mode = .hide

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
            if Self.mode == .hide { entry.window?.alphaValue = 0 }
            entry.window?.ignoresMouseEvents = true
        }
        #if DEBUG
        UpdateHarness.mark("windows_\(Self.mode == .hide ? "hidden" : "frozen").\(hidden.count)")
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
