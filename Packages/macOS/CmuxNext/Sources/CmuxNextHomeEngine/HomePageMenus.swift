public import AppKit
import CmuxHomeCore
public import CmuxNextActions
import CmuxNextDesign
import CmuxNextHome

/// The Home page's compose-button menu. Each runs its catalog action
/// through the registry (the CLI and `cmux action run` reach the same
/// handler), so the menu adds no second code path.
@MainActor
public enum HomePageMenus {
    /// The menu around the conversations: New Message, New Chief, Invite and Invite to Team,
    /// each its catalog action (the toolbar's compose button runs New Message), then, when the
    /// account has more than one team, Switch Active Team with each team (the active one checked):
    /// Home lists one team's people at a time, and this switches which.
    public static func backgroundMenu(registry: ActionRegistry) -> NSMenu {
        let menu = NSMenu()
        for (id, symbol): (ActionID, String) in [("home.newMessage", "square.and.pencil"), ("home.newChief", "sparkles"), ("home.invite", "envelope"),
                                                  ("home.inviteToTeam", "person.2.badge.plus")] {
            // Invite to Team needs a signed-in account with a team (its reason says why not).
            if id == "home.inviteToTeam", registry.unavailableReason(for: id) != nil { continue }
            guard let title = registry.descriptor(for: id)?.title else { continue }
            menu.addItem(HomeMenuTarget.item(title: title, symbol: symbol) {
                _ = registry.perform(id, invocation: ActionInvocation(origin: .user))
            })
        }
        // Conversations deleted from the list come back from here (and the palette, `cmux home show-hidden`).
        if let title = registry.descriptor(for: "home.showHiddenConversations")?.title {
            menu.addItem(.separator())
            menu.addItem(HomeMenuTarget.item(title: title, symbol: "eye") {
                _ = registry.perform("home.showHiddenConversations", invocation: ActionInvocation(origin: .user))
            })
        }
        if let teams = teamMenu(registry: registry) {
            menu.addItem(.separator())
            menu.addItem(teams)
        }
        return menu
    }

    /// Switch Active Team (`openTeamPicker`, the palette's and the CLI's one path) as a submenu
    /// of the account's teams, or nil with fewer than two teams or while it is unavailable.
    static func teamMenu(registry: ActionRegistry) -> NSMenuItem? {
        let action: ActionID = "openTeamPicker"
        let teams = registry.argumentSuggestions?(ActionSuggestions.cloudTeams) ?? []
        guard teams.count > 1, let descriptor = registry.descriptor(for: action), registry.unavailableReason(for: action) == nil else { return nil }
        let active = registry.choiceState?(action, nil)
        let submenu = NSMenu()
        for team in teams {
            let item = HomeMenuTarget.item(title: team.title, symbol: "person.2") {
                _ = registry.perform(action, invocation: ActionInvocation(arguments: ["team": .string(team.value)], origin: .user))
            }
            item.image = nil
            item.state = team.value == active ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: descriptor.title, action: nil, keyEquivalent: "")
        item.image = NSImage.menuSymbol("person.2")
        item.submenu = submenu
        return item
    }
}

/// A menu item's closure, run by `HomeMenuTarget`.
final class HomeMenuRun: NSObject {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }
}

/// The target of the Home page's closure menu items.
final class HomeMenuTarget: NSObject {
    static let shared = HomeMenuTarget()

    static func item(title: String, symbol: String, run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = shared
        item.representedObject = HomeMenuRun(run)
        item.image = NSImage.menuSymbol(symbol)
        return item
    }

    @objc func fire(_ sender: NSMenuItem) { (sender.representedObject as? HomeMenuRun)?.run() }
}
