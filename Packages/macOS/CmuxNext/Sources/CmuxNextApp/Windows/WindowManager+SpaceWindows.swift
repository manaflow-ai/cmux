import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

// Which window shows each space, for the switcher's window marks (design/spaces.md "The switcher (PR 3)"; Leo
// 2026-10-29: "having windows be switchable in this way"). The rules are `SpaceSwitcherLogic`'s; this reads the windows.
extension WindowManager {
    /// Every open window with the space it shows, front first.
    func spacesShown() -> [SpaceWindowShowing] {
        let value = registry.value
        let order = Dictionary(value.recency.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return value.openWindows.sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }.compactMap { window in
            states[window.id].map {
                SpaceWindowShowing(windowID: window.id, space: SidebarProfileKey($0.profileID.rawValue),
                                   incognito: value.isIncognito(window.id) || incognitoSpaces[window.id] != nil)
            }
        }
    }

    /// Go to Window: the frontmost other window showing `profile` comes to the front. None does: nothing happens.
    func goToWindow(showing profile: ProfileID, from state: WindowState) {
        let shown = SpaceSwitcherLogic.shownElsewhere(spacesShown(), here: state.id)
        guard let target = shown[SidebarProfileKey(profile.rawValue)], let controller = controller(for: target.windowID) else { return }
        bringToFront(controller)
    }
}
