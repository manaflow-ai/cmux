public import AppKit

/// A click on a link, by its modifiers and button.
public nonisolated enum BrowserLinkGesture: String, Hashable, Sendable, CaseIterable, Codable {
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

    /// The gesture of a click with `flags` on `button` (2 is the middle button). Command wins over
    /// Shift alone and Option; Control and other modifiers are ignored, as in Chrome
    /// (cmux-browser-rules `Gesture::of`).
    public init(flags: NSEvent.ModifierFlags, button: Int) {
        self = BrowserRules.call("browser_rules_link_gesture", BrowserLinkClickFacts(flags: flags, button: button),
                                 as: Self.self) ?? .plain
    }
}

/// What a link click does.
public nonisolated enum BrowserLinkAction: String, Hashable, Sendable, CaseIterable, Codable {
    /// Loads the link in the tab that shows it.
    case currentTab
    /// A new unselected tab next to the opener.
    case backgroundTab
    /// A new selected tab next to the opener.
    case foregroundTab
    /// Where the host puts every link the person opens (`layout.linkPlacement`;
    /// default: the pane right of the opener's pane, or a new split there).
    case linkPlacement
    /// A new cmux window (a new workspace holding the tab).
    case newWindow
    /// Downloads the link target.
    case download

}

/// What each modified link click does, for both engines (cmux.json
/// `browser.links.*`; the App maps the parsed setting to this value). A
/// plain click always loads the link in the current tab (a page's own
/// `target=_blank` opens a selected tab).
public nonisolated struct BrowserLinkClickMapping: Hashable, Sendable, Codable {
    public var cmdClick: BrowserLinkAction
    public var cmdShiftClick: BrowserLinkAction
    public var shiftClick: BrowserLinkAction
    public var optionClick: BrowserLinkAction
    public var middleClick: BrowserLinkAction

    /// Chrome's defaults (what a script's request without a user gesture
    /// follows). cmux's own Cmd-click default (`linkPlacement`) comes from
    /// cmux.json `browser.links.cmdClick`.
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

    /// What `gesture` does (cmux-browser-rules `ClickMapping::action`). Chrome treats the middle
    /// button like Command, so a Shift-middle click follows `cmdShiftClick`.
    public func action(for gesture: BrowserLinkGesture) -> BrowserLinkAction {
        struct Request: Encodable { let mapping: BrowserLinkClickMapping; let gesture: BrowserLinkGesture }
        return BrowserRules.call("browser_rules_link_action", Request(mapping: self, gesture: gesture),
                                 as: BrowserLinkAction.self) ?? .currentTab
    }
}

/// A link click's modifiers and button (and the mapping it goes through), as the link rules read
/// them.
nonisolated struct BrowserLinkClickFacts: Encodable {
    let command, shift, option: Bool
    let button: Int
    let mapping: BrowserLinkClickMapping?

    init(flags: NSEvent.ModifierFlags, button: Int, mapping: BrowserLinkClickMapping? = nil) {
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        self.button = button
        self.mapping = mapping
    }
}
