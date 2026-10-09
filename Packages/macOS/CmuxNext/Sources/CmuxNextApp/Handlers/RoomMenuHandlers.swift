import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextSidebar

/// The space menu's own action and lists (SIDEBAR-FOOTER-AND-SPACE-MENU F3):
/// New Group in a space, and the browser profiles its Set Browser Profile
/// submenu offers. The other rows are the room and browser profile actions.
enum RoomMenuHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("space.newGroup", requires: DaemonCapabilities.shared.profiles, daemon: context.services.machines.local, run: { invocation in
            try context.requireRooms()
            let room = try context.room(invocation)
            guard let state = context.activeWindow?.state else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
            if state.profileID != room.id {
                // A group is made where the window shows it; only the user
                // may move the window to another space (automation never
                // changes what a window shows).
                guard invocation.origin == .user else { throw ActionFailure.invalidTarget(RoomMenuStrings.spaceNotShown) }
                context.services.windows.switchProfile(room.id, in: state)
            }
            let name = invocation["name"]?.stringValue ?? ""
            // A person gets the new group's name editor; the group goes if it
            // is still empty when the editor closes (cx-rcby). Automation keeps it.
            if invocation.origin == .user, name.isEmpty { return try context.sidebar().newEmptyGroup(name: name) }
            try context.sidebar().handle(.createGroup(.make(), name: name, color: .grey, workspaces: []))
        })
        let targets = PaletteSourcesBridge.targetSource(context.services)
        registry.targetChoices = { [weak services = context.services] action, kind, target in
            guard let services else { return nil }
            let cases = targets.targets(of: kind).map { ActionEnumCase(value: $0.id, title: $0.title) }
            return ActionTargetChoices(cases: cases, current: current(action, target: target, services))
        }
    }

    /// The checked row: the space's browser profile (Default when unset).
    @MainActor
    static func current(_ action: ActionID, target: ActionTargetRef?, _ services: AppServices) -> String? {
        guard action == "browserProfile.setSpaceDefault", let target, target.kind == .profile,
              let room = services.machines.local.store.profile(ProfileID(rawValue: target.id)) else { return nil }
        return room.browserProfileID?.rawValue ?? BrowserProfileRecord.defaultID
    }
}

/// Strings of the space menu handlers (Resources/Rooms.xcstrings).
nonisolated enum RoomMenuStrings {
    static var spaceNotShown: String {
        String(localized: "rooms.refusal.spaceNotShown", defaultValue: "the space is not shown in the active window; switch to it first",
               table: "Rooms", bundle: .module)
    }
}
