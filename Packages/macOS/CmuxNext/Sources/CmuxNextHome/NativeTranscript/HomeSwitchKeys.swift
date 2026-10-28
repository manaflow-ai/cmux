import Foundation

/// What Home's first-run "Switching" card shows: each key as the app's
/// live binding table has it (nil hides that line), and whether macOS
/// Mission Control takes the tabs-by-number keys first.
public struct HomeSwitchKeys: Sendable, Equatable {
    /// Select tab 1…9 in the focused pane (`⌃1…9`).
    public var tabByNumber: String?
    /// Select workspace 1…9 (`⌘1…9`).
    public var workspaceByNumber: String?
    /// Previous and next tab (`⇧⌘[ ⇧⌘]`).
    public var nextPreviousTab: String?
    /// Previous and next workspace (`⌃⌘[ ⌃⌘]`).
    public var nextPreviousWorkspace: String?
    /// Focus Back and Forward (`⌘[ ⌘]`).
    public var focusBackForward: String?
    /// Mission Control's Switch to Desktop uses the tabs-by-number keys:
    /// the card shows a one-line note and a button to Keyboard Shortcuts settings.
    public var desktopConflict: Bool

    /// Creates the card's content.
    public init(tabByNumber: String?, workspaceByNumber: String?, nextPreviousTab: String?,
                nextPreviousWorkspace: String?, focusBackForward: String?, desktopConflict: Bool = false) {
        self.tabByNumber = tabByNumber
        self.workspaceByNumber = workspaceByNumber
        self.nextPreviousTab = nextPreviousTab
        self.nextPreviousWorkspace = nextPreviousWorkspace
        self.focusBackForward = focusBackForward
        self.desktopConflict = desktopConflict
    }

    /// The card's lines in order: a label and its keys; keys nothing runs are left out.
    var lines: [(label: String, keys: String)] {
        [(HomeStrings.switchKeysTabs, tabByNumber), (HomeStrings.switchKeysWorkspaces, workspaceByNumber),
         (HomeStrings.switchKeysNextTab, nextPreviousTab), (HomeStrings.switchKeysNextWorkspace, nextPreviousWorkspace),
         (HomeStrings.switchKeysFocus, focusBackForward)]
            .compactMap { line in line.1.map { (line.0, $0) } }
    }
}
