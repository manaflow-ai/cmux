import os
import CmuxNextCompat
public import Observation

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

/// Which spaces other windows show, for one window's switcher (design/spaces.md "The switcher (PR 3)"). `install`
/// fills it from the App's windows (`SpaceWindowSource`) and runs `perform`; the bar draws the marks and offers the
/// choices from it.
@Observable @MainActor public final class SpaceWindowMarks {
    /// The spaces other open windows show, each with the frontmost one.
    public var elsewhere: [ProfileKey: SpaceElsewhere] = [:]
    /// This window is incognito: Move Here is never offered (incognito and normal content never mix).
    public var windowIsIncognito = false
    /// Runs a switcher choice (the App's one path: the window registry and `space.bringHere`).
    @ObservationIgnored public var perform: ((SpaceWindowAction) -> Void)?
    /// The bar is in a window (`ProfileBarView.viewDidMoveToWindow`): the marks observe the windows only then, so a
    /// closed window's switcher leaves no observer behind.
    @ObservationIgnored public var isActive = false {
        didSet { if isActive != oldValue { restartObservation() } }
    }
    @ObservationIgnored private weak var source: (any SpaceWindowSource)?
    @ObservationIgnored private var windowID: (@MainActor @Sendable () -> String?)?
    /// The observation task, in a lock so the nonisolated deinit can cancel it without a main-actor hop.
    @ObservationIgnored private let observation = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    public init() {}

    // A dropped `Task` handle does not cancel its task: cancel the observation here (#38333 review).
    // cx-t7hu: nonisolated; the lock is a Sendable let, so cancelling needs no main-actor hop.
    nonisolated deinit { observation.withLock { $0?.cancel() } }

    /// The marks observe the windows now (tests: a closed window's switcher leaves no observer behind).
    var isObserving: Bool { observation.withLock { $0 != nil } }
    /// The observation task itself (tests: releasing the marks cancels it).
    var observationTask: Task<Void, Never>? { observation.withLock { $0 } }
}

/// The App's side of one window's switcher (`SpaceWindowMarks.install`): it reads the open windows and runs a choice.
/// The rules stay in this package; the App only answers from its window registry.
@MainActor public protocol SpaceWindowSource: AnyObject, Sendable {
    /// Every open window with the space it shows, front first. Read inside an observation: what it reads is tracked.
    func spaceWindowsShowing() -> [SpaceWindowShowing]
    /// The window is incognito.
    func spaceWindowIsIncognito(_ windowID: String) -> Bool
    /// Bring the window to the front (Go to Window).
    func spaceWindowBringToFront(_ windowID: String)
    /// Move the space into the window and show it there (Move Here, `space.bringHere`).
    func spaceWindowBringHere(_ space: ProfileKey, window windowID: String)
    /// Open a new incognito space (`space.newIncognito`).
    func spaceWindowNewIncognitoSpace()
}

extension SpaceWindowMarks {
    /// Fills the marks for the window `windowID` names from `source` and runs the switcher's choices through it.
    /// Event-driven (Observation of what `source` and `windowID` read), only while `isActive`. Leo 2026-10-29: "having
    /// windows be switchable in this way". `windowID` is read live: the window opened at launch takes a restored
    /// record's id later (`WindowState.adopt`), and a stale id would ring this window's own space as another window's.
    public func install(source: any SpaceWindowSource, windowID: @escaping @MainActor @Sendable () -> String?) {
        perform = { [weak source] action in
            guard let source, let here = windowID() else { return }
            switch action {
            case .goToWindow(let space):
                guard let target = SpaceSwitcherLogic.shownElsewhere(source.spaceWindowsShowing(), here: here)[space]
                else { return }
                source.spaceWindowBringToFront(target.windowID)
            case .moveHere(let space):
                source.spaceWindowBringHere(space, window: here)
            case .newIncognitoSpace:
                source.spaceWindowNewIncognitoSpace()
            }
        }
        self.source = source
        self.windowID = windowID
        restartObservation()
    }

    /// The window closed (`SidebarBridge.teardown`): stops the observation and drops the source for good, so a reused or
    /// retained bar never observes again. A retained window keeps its views, so `isActive` alone may never turn off.
    public func tearDown() {
        perform = nil
        source = nil
        windowID = nil
        restartObservation()
    }

    /// Observes the windows while the bar is in a window and `install` has given a source; cancels otherwise.
    private func restartObservation() {
        observation.withLock { $0?.cancel(); $0 = nil }
        guard isActive, let source, let windowID else { return }
        // task-owner: `observation`, cancelled when the bar leaves its window (`isActive`) or the window closes (`tearDown`);
        // event-driven (Observation)
        let task = Task { [weak self, weak source] in
            for await value in ObservationStream({ () -> ([ProfileKey: SpaceElsewhere], Bool)? in
                guard let source else { return nil }
                let here = windowID() ?? ""
                return (SpaceSwitcherLogic.shownElsewhere(source.spaceWindowsShowing(), here: here),
                        source.spaceWindowIsIncognito(here))
            }) {
                guard !Task.isCancelled, let self, let value else { return }
                if elsewhere != value.0 { elsewhere = value.0 }
                if windowIsIncognito != value.1 { windowIsIncognito = value.1 }
            }
        }
        observation.withLock { $0 = task }
    }
}
