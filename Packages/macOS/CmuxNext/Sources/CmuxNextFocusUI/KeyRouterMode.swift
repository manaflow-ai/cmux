/// An owner that takes typing keys before the focused view while it is on. The App's key router
/// asks each one, in its fixed order, only while some mode is on; with none on (normal mode), a typing key (no
/// Command or Control, not Escape) skips them all.
///
/// Only owners that can take a typing key have a mode. The router's other early owners take only chords or Escape
/// (a missed sheet's or dialog's Escape, Cmd-Z for an undo toast, a popup's Cmd-W and Cmd-L, the native palette's
/// Cmd-P), which are never typing keys, so the router still asks them for those keys in every mode.
public nonisolated enum KeyRouterMode: Int, CaseIterable, Sendable {
    /// Keys typed after Cmd-T or Cmd-N wait for the New Tab field (`NewTabInputCoordinator`).
    case newTabCapture
    /// Keys typed after a split or a new terminal tab wait for the new terminal (`CreationInputCoordinator`).
    case creationCapture
    /// The Keyboard Shortcuts page records keys.
    case recorder
    /// Link hints show on a Chromium page: their letters pick a link.
    case linkHints
    /// Click by Hint labels show over a window, or wait for its pages: their letters pick a control.
    case windowHints
    /// Browser focus mode's exit is armed (one Escape typed): any other key disarms it.
    case focusModeEscape
    /// A chord (`ctrl+b c`, the Cmd-J leader) waits for its next key.
    case chord
    /// A window shows its launch picture, or keys wait for a terminal it showed (`LaunchPictureKeys`).
    case launchPicture

    var bit: UInt16 { 1 << UInt16(rawValue) }
}

/// The key router's modes, kept by their owners as they enter and leave them, so the router reads one word per
/// typing key instead of asking every owner. Chrome does the same for a key with no accelerator:
/// `BrowserView::PreHandleKeyboardEvent` (chrome/browser/ui/views/frame/browser_view.cc) returns at once when the
/// focus manager has no accelerator registered for it (`ui::AcceleratorManager::IsRegistered`, a map lookup), before
/// any command or browser state is read.
///
/// A mode left on only costs the slow path (every owner is asked, as before); a mode an owner never enters would
/// skip that owner, so each owner sets its mode from the same stored state that makes it active (a `didSet` on it).
@MainActor
public final class KeyRouterModes {
    private var bits: UInt16 = 0
    /// How many times a mode turned on or off (tests, `debug.key`).
    public private(set) var transitions = 0

    public init() {}

    /// No mode is on: a typing key goes straight to the focused view.
    public var isNormal: Bool { bits == 0 }

    /// Whether `mode` is on.
    public func contains(_ mode: KeyRouterMode) -> Bool { bits & mode.bit != 0 }

    /// The modes that are on, in declaration order (`debug.key`, tests).
    public var active: [KeyRouterMode] { KeyRouterMode.allCases.filter { contains($0) } }

    /// Turns `mode` on or off; its owner calls this whenever the state that makes it active changes.
    public func set(_ mode: KeyRouterMode, _ on: Bool) {
        let next = on ? bits | mode.bit : bits & ~mode.bit
        guard next != bits else { return }
        bits = next
        transitions += 1
    }
}
