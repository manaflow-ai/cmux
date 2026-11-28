public import AppKit

/// A click on a link, by its modifiers and button.
public nonisolated enum BrowserLinkGesture: Hashable, Sendable, CaseIterable {
    /// No modifier, left button.
    case plain
    case cmd
    case cmdShift
    /// Shift alone.
    case shift
    /// Option alone.
    case option
    /// The middle button.
    case middle
    /// The middle button with Shift.
    case middleShift

    /// Pure: the gesture of a click with `flags` on `button` (2 is the
    /// middle button). Command wins over Shift alone and Option; Control
    /// and other modifiers are ignored, as in Chrome.
    public init(flags: NSEvent.ModifierFlags, button: Int) {
        let flags = flags.intersection([.command, .shift, .option])
        let shift = flags.contains(.shift)
        if flags.contains(.command) {
            self = shift ? .cmdShift : .cmd
        } else if button == 2 {
            self = shift ? .middleShift : .middle
        } else if flags == .shift {
            self = .shift
        } else if flags == .option {
            self = .option
        } else {
            self = .plain
        }
    }
}

/// What a link click does.
public nonisolated enum BrowserLinkAction: String, Hashable, Sendable, CaseIterable {
    /// Loads the link in the tab that shows it.
    case currentTab
    /// A new unselected tab next to the opener.
    case backgroundTab
    /// A new selected tab next to the opener.
    case foregroundTab
    /// A new cmux window (a new workspace holding the tab).
    case newWindow
    /// Downloads the link target.
    case download

    /// The new tab's disposition; nil when no new tab opens.
    public var newTabDisposition: BrowserNewTabDisposition? {
        switch self {
        case .backgroundTab: .backgroundTab
        case .foregroundTab: .foregroundTab
        case .newWindow: .newWindow
        case .currentTab, .download: nil
        }
    }
}

/// What each modified link click does, for both engines (cmux.json
/// `browser.links.*`; the App maps the parsed setting to this value). A
/// plain click always loads the link in the current tab (a page's own
/// `target=_blank` opens a selected tab).
public nonisolated struct BrowserLinkClickMapping: Hashable, Sendable {
    public var cmdClick: BrowserLinkAction
    public var cmdShiftClick: BrowserLinkAction
    public var shiftClick: BrowserLinkAction
    public var optionClick: BrowserLinkAction
    public var middleClick: BrowserLinkAction

    /// Chrome's defaults.
    public static let chrome = BrowserLinkClickMapping()

    public init(cmdClick: BrowserLinkAction = .backgroundTab, cmdShiftClick: BrowserLinkAction = .foregroundTab,
                shiftClick: BrowserLinkAction = .newWindow, optionClick: BrowserLinkAction = .download,
                middleClick: BrowserLinkAction = .backgroundTab) {
        self.cmdClick = cmdClick
        self.cmdShiftClick = cmdShiftClick
        self.shiftClick = shiftClick
        self.optionClick = optionClick
        self.middleClick = middleClick
    }

    /// Pure: what `gesture` does. Chrome treats the middle button like
    /// Command, so a Shift-middle click follows `cmdShiftClick`.
    public func action(for gesture: BrowserLinkGesture) -> BrowserLinkAction {
        switch gesture {
        case .plain: .currentTab
        case .cmd: cmdClick
        case .cmdShift, .middleShift: cmdShiftClick
        case .shift: shiftClick
        case .option: optionClick
        case .middle: middleClick
        }
    }
}
