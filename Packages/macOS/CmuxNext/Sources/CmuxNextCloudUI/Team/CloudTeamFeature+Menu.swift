import AppKit
import CmuxNextActions

extension CloudTeamFeature {
    /// A Team row's right-click menu: Follow or Unfollow, Reassign To (the team's other members),
    /// Copy Link and Archive or Restore. Every row is the registry's row of its `cloud.team.*`
    /// action on that session, so the menu, the palette and `cmux cloud …` run the same handler.
    func makeRowMenu(_ row: CloudTeamSession, members: [CloudTeamMember]) -> NSMenu? {
        guard let registry else { return nil }
        let session: [String: ActionValue] = ["session": .string(row.key)]
        func item(_ id: ActionID, _ title: String, _ extra: [String: ActionValue] = [:]) -> NSMenuItem? {
            registry.makeArgumentMenuItem(for: id, arguments: session.merging(extra) { $1 }, title: title)
        }
        let menu = NSMenu()
        if row.canFollow {
            let follow = row.following
                ? item("cloud.team.unfollow", CloudTeamStrings.unfollow)
                : item("cloud.team.follow", CloudTeamStrings.follow)
            if let follow { menu.addItem(follow) }
        }
        if row.canReassign {
            let others = NSMenu()
            for member in members where member.canBeAssigned && member.user != row.assignee {
                if let to = item("cloud.team.reassign", member.name, ["to": .string(member.user)]) { others.addItem(to) }
            }
            if others.items.isEmpty {
                // No action: AppKit shows it disabled.
                others.addItem(NSMenuItem(title: CloudTeamStrings.noMembers, action: nil, keyEquivalent: ""))
            }
            let reassign = NSMenuItem(title: CloudTeamStrings.reassign, action: nil, keyEquivalent: "")
            reassign.submenu = others
            menu.addItem(reassign)
        }
        // No default shortcut: Cmd-Shift-C is the browser's Copy URL.
        if let copy = item("cloud.team.copyLink", CloudTeamStrings.copyLink) { menu.addItem(copy) }
        if row.canArchive, let archive = item("cloud.team.archive", row.archived ? CloudTeamStrings.restore : CloudTeamStrings.archive,
                                              ["archived": .bool(!row.archived)]) {
            menu.addItem(.separator())
            menu.addItem(archive)
        }
        return menu
    }
}
