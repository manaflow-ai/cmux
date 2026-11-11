/// What a click on a space mark does (`SpaceSwitcherLogic.click`).
public nonisolated enum SpaceClick: Hashable, Sendable {
    /// Nothing (the current space, which no other window shows).
    case none
    /// Show the space in this window.
    case switchHere
    /// This window takes the space from the other window that shows it, and shows it (`space.bringHere`). The click
    /// never raises that window: a window is a space, and every space is one click away in any window (Leo 2026-11-11:
    /// "it's essentially all the same window in a way if you want it to be").
    case pullHere
    /// Open the whole space menu (the `menu` style's current space).
    case spaceMenu
}

/// The pure rules of the switcher: which spaces other windows show, and what a click on a space does.
public nonisolated struct SpaceSwitcherLogic {
    public nonisolated init() {}
    /// The spaces open windows other than `here` show, each with the frontmost such window. `windows` runs
    /// front to back. A space this window shows itself is still listed when another window shows it too.
    public static func shownElsewhere(_ windows: [SpaceWindowShowing], here: String) -> [ProfileKey: SpaceElsewhere] {
        var result: [ProfileKey: SpaceElsewhere] = [:]
        for window in windows where window.windowID != here && result[window.space] == nil {
            result[window.space] = SpaceElsewhere(windowID: window.windowID, incognito: window.incognito)
        }
        return result
    }

    /// What a click on `space` does in a window showing `active`, under `style`. Every style switches this window: a
    /// space another normal window shows comes here (`pullHere`), its own space too when another window also shows it.
    /// Incognito never mixes with normal content (design/spaces.md "Incognito"): an incognito space, or any space from
    /// an incognito window, takes the plain switch, whose own rule shows the incognito space's window.
    public static func click(_ space: ProfileKey, active: ProfileKey?, elsewhere: SpaceElsewhere?, hereIsIncognito: Bool,
                             style: SpaceSwitcherStyle) -> SpaceClick {
        if space == active, style == .menu { return .spaceMenu }
        if let elsewhere, !elsewhere.incognito, !hereIsIncognito { return .pullHere }
        return space == active ? .none : .switchHere
    }
}
