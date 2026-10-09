import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDesign
import CmuxNextSidebar
import Observation

/// The sidebar's profile control (SIDEBAR-FOOTER-AND-SPACE-MENU amendment
/// 2): the current profile's avatar on the footer's account item
/// (`SidebarModel.profileAvatar`), and the one profile menu its click opens.
/// The current profile is the browser profile new tabs of the selected
/// workspace get (workspace, then space, then Default); real profile
/// switching and creating are a later lane. Signed in, the control shows the
/// cmux user instead and the menu says who it is, with Sign Out (#17601).
@MainActor struct SidebarProfileControl {
    let services: AppServices

    /// Keeps `model.profileAvatar` current and gives `sidebar` its menu.
    func install(model: SidebarModel, sidebar: SidebarView) {
        sidebar.profileMenuProvider = { [weak model] in model.map { menu(workspace: $0.activeWorkspaceID?.rawValue) } }
        let control = self
        // task-owner: ends with the model (the window's sidebar); event-driven (Observation)
        Task { [weak model] in
            for await avatar in Observations({ [weak model] in Self.avatar(profile: control.avatar(workspace: model?.activeWorkspaceID?.rawValue), account: control.account) }) {
                guard let model else { return }
                if model.profileAvatar != avatar { model.profileAvatar = avatar }
            }
        }
    }

    func avatar(workspace: String?) -> SidebarAvatar {
        let profiles = services.browserProfiles
        let id = profiles.effectiveProfile(forWorkspace: workspace)
        let record = profiles.record(id)
        return SidebarAvatar(name: record?.name ?? profiles.displayName(id), color: record?.color.flatMap(GroupColor.init(rawValue:)))
    }

    /// The control's avatar: the signed-in user's, else the current profile's.
    static func avatar(profile: SidebarAvatar, account: SidebarAccount?) -> SidebarAvatar {
        account?.avatar ?? profile
    }

    /// The signed-in user, starting their picture's fetch.
    private var account: SidebarAccount? {
        AccountAvatarImages.shared.load(services.cloud?.auth.user?.profileImageURL)
        return SidebarAccount(services.cloud?.auth)
    }

    func menu(workspace: String?) -> NSMenu {
        let avatar = avatar(workspace: workspace)
        let menu = ProfileMenuBuilder(registry: services.registry).make(profile: ProfileMenuProfile(name: avatar.name, initial: avatar.initial))
        SidebarAccount.addRows(to: menu, account: account, registry: services.registry)
        return menu
    }
}
