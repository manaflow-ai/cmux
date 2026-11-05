import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSidebar

/// Fills one window's switcher marks with the spaces other windows show and runs the switcher's choices
/// (design/spaces.md "The switcher (PR 3)"; Leo 2026-10-29: "having windows be switchable in this way"). The rules are
/// `SpaceSwitcherLogic`'s; this reads the windows. Go to Window brings the frontmost other window on the space to the
/// front; Move Here runs `space.bringHere` for this window (it refuses incognito); New Incognito Space runs
/// `space.newIncognito`.
@MainActor struct SpaceWindowMarksWiring {
    let services: AppServices
    weak var state: WindowState?

    /// Event-driven (Observation of the window registry and each window's space); ends with `marks` (the window's bar).
    func install(_ marks: SpaceWindowMarks) {
        guard let state else { return }
        let windows = services.windows, registry = services.registry, id = state.id
        marks.perform = { [weak state] action in
            guard let state else { return }
            switch action {
            case .goToWindow(let space):
                guard let target = SpaceSwitcherLogic.shownElsewhere(Self.shown(windows), here: state.id)[space],
                      let controller = windows.controller(for: target.windowID) else { return }
                windows.bringToFront(controller)
            case .moveHere(let space):
                var invocation = ActionInvocation(target: ActionTargetRef(kind: .profile, id: space.rawValue), origin: .user)
                invocation.arguments["window"] = .target(ActionTargetRef(kind: .window, id: state.id))
                registry.perform("space.bringHere", invocation: invocation)
            case .newIncognitoSpace:
                registry.perform("space.newIncognito", invocation: ActionInvocation())
            }
        }
        // task-owner: ends with the marks (the window's switcher); event-driven (Observation)
        Task { [weak marks] in
            for await value in ObservationStream({ (SpaceSwitcherLogic.shownElsewhere(Self.shown(windows), here: id), windows.isIncognito(window: id)) }) {
                guard let marks else { return }
                if marks.elsewhere != value.0 { marks.elsewhere = value.0 }
                if marks.windowIsIncognito != value.1 { marks.windowIsIncognito = value.1 }
            }
        }
    }

    /// Every open window with the space it shows, front first.
    static func shown(_ windows: WindowManager) -> [SpaceWindowShowing] {
        let value = windows.registry.value
        let order = Dictionary(value.recency.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return value.openWindows.sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }.compactMap { window in
            windows.states[window.id].map {
                SpaceWindowShowing(windowID: window.id, space: SidebarProfileKey($0.profileID.rawValue),
                                   incognito: value.isIncognito(window.id) || windows.incognitoSpaces[window.id] != nil)
            }
        }
    }
}
