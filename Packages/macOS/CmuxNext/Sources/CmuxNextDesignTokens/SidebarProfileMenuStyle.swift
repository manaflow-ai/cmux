/// `sidebar.profileMenu.style` (Leo, ask-aad661801e: "make customization for codex, t3code, claude
/// code app (everything)"): what the profile button at the sidebar's foot opens.
///
/// The app menu (the default) is cmux's own: New Workspace, Extensions, History, Cloud, Settings,
/// Help, Sign In. The account menu puts the person first, as the Claude Code and Codex apps'
/// account menus do: the signed-in account and its teams to switch between, then Settings, Usage,
/// Help and Sign Out.
public nonisolated enum SidebarProfileMenuStyle: String, Hashable, Sendable, CaseIterable {
    /// cmux's app menu; the default.
    case app
    /// An account-first menu: accounts and switching, Settings, Usage, Help, Sign Out.
    case account
}
