public import CmuxNextApps
import CmuxNextIcons
public import CmuxNextSidebar

/// How the sidebar draws app items (a layout item whose ref is `.app(id)`), from the apps the
/// supervisor lists. Made per pass by the App's sidebar (`SidebarBridge.observeSections`), which
/// reads the client and Labs in its observation so a change draws again.
///
/// ```swift
/// let info = SidebarAppItemInfo(client: apps, showsStore: settings.snapshot.showsAppStore).info("cmux/home")
/// ```
@MainActor
public struct SidebarAppItemInfo {
    /// The apps the supervisor lists, with each app's manifest, install and hidden state.
    let client: AppsClient
    /// Whether the App Store's own item shows: false while it is hidden until it is ready
    /// (`CmuxConfigSnapshot.showsAppStore`, Labs off).
    let showsStore: Bool

    /// - Parameters:
    ///   - client: The apps the supervisor lists.
    ///   - showsStore: Whether the App Store's item shows; true when the caller has no such gate.
    public init(client: AppsClient, showsStore: Bool = true) {
        self.client = client
        self.showsStore = showsStore
    }

    /// How app `id`'s item draws: its name and symbol; hidden while the app is hidden or not active
    /// (D55), and the App Store's while ``showsStore`` is false; dimmed when the supervisor's list says
    /// it is not installed (never before that list lands).
    /// - Parameter id: The app's id (`cmux/home`, `cmux/app-store`, a third-party app's).
    /// - Returns: The item's presentation.
    public func info(_ id: String) -> SidebarItemInfo {
        var info = presentation(id)
        if !showsStore, SidebarBuiltIn.firstParty(appID: id) == .appStore { info.isHidden = true }
        return info
    }

    private func presentation(_ id: String) -> SidebarItemInfo {
        guard let app = client.app(id) else {
            var info = SidebarItemInfo.fallback(for: .app(id))
            // Before the supervisor's list (an older daemon, not connected): unknown, not missing.
            if !client.isListed { info.isMissing = false }
            return info
        }
        let symbol = if case .symbol(let name)? = app.manifest.icon { name } else { "app" }
        // A first-party app keeps its former built-in's icon and tile caption; no symbol draws the generic app.
        let firstParty = SidebarBuiltIn.firstParty(appID: id), icon = firstParty?.icon ?? (symbol == "app" ? IconName.appGeneric : nil)
        return SidebarItemInfo(title: app.manifest.name.resolved(), symbol: symbol, icon: icon, isMissing: !app.installed,
                               isHidden: AppPresence([app]).suppressed.contains(id), caption: firstParty?.caption)
    }
}
