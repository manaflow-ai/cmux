import Observation

/// Another open window that shows a space (`SpaceSwitcherLogic.shownElsewhere`).
public nonisolated struct SpaceElsewhere: Hashable, Sendable {
    /// The window showing the space (the frontmost one when several do).
    public var windowID: String
    /// That window is incognito: the space never moves between it and a normal window.
    public var incognito: Bool

    public init(windowID: String, incognito: Bool) {
        self.windowID = windowID
        self.incognito = incognito
    }
}

/// What the switcher asks the App to do for a space another window shows.
public nonisolated enum SpaceWindowAction: Hashable, Sendable {
    /// Bring the window that shows the space to the front (Go to Window, Option-click).
    case goToWindow(ProfileKey)
    /// Move the space into this window (Move Here, `space.bringHere`).
    case moveHere(ProfileKey)
    /// Open a new incognito space (the space menu's New Incognito Space, `space.newIncognito`).
    case newIncognitoSpace
}

/// Which spaces other windows show, for one window's switcher (design/spaces.md "The switcher (PR 3)"). The App fills
/// it (`SpaceWindowMarksWiring`) and runs `perform`; the bar draws the marks and offers the choices from it.
@Observable @MainActor public final class SpaceWindowMarks {
    /// The spaces other open windows show, each with the frontmost one.
    public var elsewhere: [ProfileKey: SpaceElsewhere] = [:]
    /// This window is incognito: Move Here is never offered (incognito and normal content never mix).
    public var windowIsIncognito = false
    /// Runs a switcher choice (the App's one path: the window registry and `space.bringHere`).
    @ObservationIgnored public var perform: ((SpaceWindowAction) -> Void)?

    public init() {}
}
