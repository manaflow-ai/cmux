import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextWakeups
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
    /// The sidebar's window: its room (`profileID`, observed) gives the avatar's room default.
    weak var state: WindowState?

    /// Gives `sidebar` its profile menu (the avatar follows through ``followAvatar(model:)``).
    func install(model: SidebarModel, sidebar: SidebarView) {
        sidebar.profileMenuProvider = { [weak model] in model.map { menu(workspace: $0.activeWorkspaceID?.rawValue) } }
    }

    /// Keeps `model.profileAvatar` current: the sidebar model's (the footer draws it), a service
    /// observation, `visible` for a profile, account or picture change. The bridge holds the token.
    func followAvatar(model: SidebarModel) -> ServiceObservation<SidebarAvatar> {
        let control = self
        return ServiceObservation(.visible, owner: "SidebarProfileControl.avatar", on: services.mainWork) { [weak model] in
            Self.avatar(profile: control.avatar(workspace: model?.activeWorkspaceID?.rawValue), account: control.account)
        } apply: { [weak model] avatar in
            guard let model, model.profileAvatar != avatar else { return }
            model.profileAvatar = avatar
        }
    }

    func avatar(workspace: String?) -> SidebarAvatar {
        let profiles = services.browserProfiles
        let id = profiles.effectiveProfile(forWorkspace: workspace, room: state?.profileID)
        let record = profiles.record(id)
        return SidebarAvatar(name: record?.name ?? profiles.displayName(id), color: record?.color.flatMap(GroupColor.init(rawValue:)))
    }

    /// The control's avatar: the signed-in user's, else the current profile's.
    static func avatar(profile: SidebarAvatar, account: SidebarAccount?) -> SidebarAvatar {
        account?.avatar ?? profile
    }

    /// The signed-in user, starting their picture's fetch.
    private var account: SidebarAccount? {
        AccountAvatarImages.shared.load(services.cloud.auth.user?.profileImageURL)
        return SidebarAccount(services.cloud.auth)
    }

    func menu(workspace: String?) -> NSMenu {
        let avatar = avatar(workspace: workspace)
        // Show Chief / Hide Chief reads the `home.chiefPetEnabled` that applies now (the menu is built at each open).
        let menu = ProfileMenuBuilder(registry: services.registry).make(profile: ProfileMenuProfile(name: avatar.name), avatar: avatar.image(diameter: Double(Metrics.smallIconSize)), chiefPetShown: services.settings?.snapshot.homeChiefPetEnabled)
        SidebarAccount.addRows(to: menu, account: account, registry: services.registry)
        return menu
    }
}
