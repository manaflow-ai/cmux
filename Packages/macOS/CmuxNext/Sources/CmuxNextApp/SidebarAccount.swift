import AppKit
import CmuxNextAccounts
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// The signed-in cmux user on the sidebar's profile control (Leo 2026-10-06): their picture or
/// initials on the control, and who is signed in, on which team, with Sign Out in its menu.
struct SidebarAccount: Hashable {
    /// The display name, else the email.
    var name: String
    var email: String?
    var imageData: Data?
    /// The selected cmux team's name; the menu bar's team row opens the team picker.
    var team: String?

    /// Nil without a name or email to show.
    init?(name: String?, email: String?, imageData: Data? = nil, team: String? = nil) {
        guard let shown = AccountName(name: name, email: email)?.text else { return nil }
        self.name = shown
        self.email = email.flatMap { $0 == shown || $0.isEmpty ? nil : $0 }
        self.imageData = imageData
        self.team = team.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The signed-in user, with their picture once it has loaded.
    @MainActor init?(_ auth: CloudAuth?) {
        guard let auth, auth.isSignedIn, let user = auth.user else { return nil }
        let picture = user.profileImageURL.flatMap { AccountAvatarImages.shared.data[$0] }
        self.init(name: user.displayName, email: user.primaryEmail, imageData: picture, team: auth.activeTeam.activeRow?.title)
    }

    var avatar: SidebarAvatar { .account(name: name, email: email, imageData: imageData) }

    /// The menu bar menu's account rows: the name, then the email, then the team with its icon (`TeamRowText.symbol`).
    func menuBarAccount(teamSymbol: String) -> MenuBarMenuState.Account { MenuBarMenuState.Account(lines: [name, email].compactMap(\.self), team: team, teamSymbol: teamSymbol) }

    /// Adds the account rows to the profile menu (`ProfileMenuBuilder.addAccountRows`).
    @MainActor static func addRows(to menu: NSMenu, account: SidebarAccount?, registry: ActionRegistry) {
        ProfileMenuBuilder(registry: registry)
            .addAccountRows(to: menu, who: account.map { [$0.name, $0.email].compactMap(\.self) },
                            avatar: account?.avatar.image(diameter: Double(Metrics.smallIconSize)))
    }
}
