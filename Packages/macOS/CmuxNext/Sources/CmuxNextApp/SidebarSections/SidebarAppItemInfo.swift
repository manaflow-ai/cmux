import CmuxNextApps
import CmuxNextIcons
import CmuxNextSidebar

/// App items in the sidebar layout (moved out of SidebarBridge, which is at
/// its god-type limit).
@MainActor
enum SidebarAppItemInfo {
    /// How an app item draws: its name and symbol; hidden while the app is
    /// hidden or not active (D55); dimmed when the app is not installed.
    static func info(_ id: String, registry: AppRegistry) -> SidebarItemInfo {
        guard let app = registry.app(id) else { return SidebarItemInfo.fallback(for: .app(id)) }
        let symbol = if case .symbol(let name)? = app.manifest.icon { name } else { "app" }
        // A first-party app keeps its former built-in's icon and tile caption; no symbol draws the generic app.
        let firstParty = SidebarBuiltIn.firstParty(appID: id), icon = firstParty?.icon ?? (symbol == "app" ? IconName.appGeneric : nil)
        return SidebarItemInfo(title: app.manifest.name.resolved(), symbol: symbol, icon: icon, isMissing: !app.isInstalled,
                               isHidden: AppPresence([app]).suppressed.contains(id), caption: firstParty?.caption)
    }
}
