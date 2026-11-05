/// What the strip offers on a space another window shows.
public nonisolated enum SpaceWindowChoice: Hashable, Sendable {
    /// Bring the window that shows it to the front (`SpaceWindowAction.goToWindow`).
    case goToWindow
    /// Move the space's workspaces into this window and show it here (`space.bringHere`).
    case moveHere
}

/// What a click on a space mark does (`SpaceSwitcherLogic.click`).
public nonisolated enum SpaceClick: Hashable, Sendable {
    /// Nothing (the current space with no other window on it, under a style with no menu on it).
    case none
    /// Show the space in this window (today's click).
    case switchHere
    /// Bring the window that shows it to the front.
    case goToWindow
    /// Offer these choices in a menu at the mark.
    case offer([SpaceWindowChoice])
    /// Open the whole space menu (the `menu` style's current space).
    case spaceMenu
}

/// The pure rules of the switcher's window marks: which spaces other windows show, and what a click offers.
public nonisolated enum SpaceSwitcherLogic {
    /// The spaces open windows other than `here` show, each with the frontmost such window. `windows` runs
    /// front to back. A space this window shows itself is still listed when another window shows it too.
    public static func shownElsewhere(_ windows: [SpaceWindowShowing], here: String) -> [ProfileKey: SpaceElsewhere] {
        var result: [ProfileKey: SpaceElsewhere] = [:]
        for window in windows where window.windowID != here && result[window.space] == nil {
            result[window.space] = SpaceElsewhere(windowID: window.windowID, incognito: window.incognito)
        }
        return result
    }

    /// The choices for a space another window shows. Move Here never joins incognito and normal content
    /// (design/spaces.md "Incognito"): neither from an incognito window nor into one.
    public static func choices(for elsewhere: SpaceElsewhere, hereIsIncognito: Bool) -> [SpaceWindowChoice] {
        elsewhere.incognito || hereIsIncognito ? [.goToWindow] : [.goToWindow, .moveHere]
    }

    /// What a click on `space` does in a window showing `active`, under `style`. `option` is Option held.
    public static func click(_ space: ProfileKey, active: ProfileKey?, elsewhere: SpaceElsewhere?, hereIsIncognito: Bool,
                             style: SpaceSwitcherStyle, option: Bool) -> SpaceClick {
        if space == active, style == .menu { return .spaceMenu }
        // This window's own space is ringed too when another window also shows it: the same choices.
        guard style.marksOtherWindows, let elsewhere else { return space == active ? .none : .switchHere }
        if option { return .goToWindow }
        return .offer(choices(for: elsewhere, hereIsIncognito: hereIsIncognito))
    }
}
