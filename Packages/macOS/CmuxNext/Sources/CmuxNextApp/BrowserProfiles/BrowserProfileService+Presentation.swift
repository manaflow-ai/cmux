import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs

/// How tabs and browser toolbars show their browser profile (data-model.md 5): the
/// toolbar's profile button draws every tab's profile; a tab whose
/// profile differs from its workspace's shows a dot.
extension BrowserProfileService {
    /// The tab strip dot of `tab`, nil when its profile is the one its
    /// workspace gives new tabs. `room`: the room of the strip's window (`roomDefault`).
    func tabBadge(for tab: TabModel, workspaceID: String?, room: ProfileID?) -> TabProfileBadge? {
        tabBadge(for: tab, workspaceEffective: effectiveProfile(forWorkspace: workspaceID, room: room))
    }

    /// `tabBadge` with the room's browser profile already resolved (`WindowState.roomBrowserProfileID`).
    func tabBadge(for tab: TabModel, workspaceID: String?, roomBrowserProfile: String?) -> TabProfileBadge? {
        let workspaceEffective = BrowserProfileCascade.resolve(explicit: nil, workspace: workspaceDefault(workspaceID), room: roomBrowserProfile,
                                                               known: isKnown)
        return tabBadge(for: tab, workspaceEffective: workspaceEffective)
    }

    private func tabBadge(for tab: TabModel, workspaceEffective: String) -> TabProfileBadge? {
        let id = profileID(ofTab: tab)
        guard BrowserProfileCascade.showsTabBadge(tabProfile: id, workspaceEffective: workspaceEffective)
        else {
            return nil
        }
        let record = record(id)
        return TabProfileBadge(name: record?.name ?? displayName(id), color: record?.color.flatMap(GroupColor.init(rawValue:)))
    }

    /// The avatar the toolbar's profile button draws for tab `key`, with one profile too (the button is
    /// where a second one is made); nil for incognito tabs (their window says incognito), which keep
    /// the plain glyph.
    func toolbarBadge(forTab key: String) -> BrowserProfileBadge? {
        guard !services.cache.browserTabs.isIncognitoTab(key) else { return nil }
        let id = services.cache.tabModel(key).map(profileID(ofTab:)) ?? BrowserProfileRecord.defaultID
        let record = record(id)
        return BrowserProfileBadge(monogram: record?.monogram ?? "?", color: record?.color.flatMap(GroupColor.init(rawValue:)),
                                   name: record?.name ?? displayName(id))
    }

    /// Whether tab `key`'s toolbar shows its profile button, and in color (`browser.profileButton`). At the
    /// default level it shows once the person has a second profile of their own (the Agents profile does
    /// not count), or for an incognito or Agents tab; always in ink unless they chose the color level.
    func toolbarPresence(forTab key: String) -> BrowserProfileButtonPresence {
        let style = services.settings.map(BrowserProfileButtonSetting.current) ?? BrowserProfileButtonSetting.fallback
        let id = services.cache.tabModel(key).map(profileID(ofTab:)) ?? BrowserProfileRecord.defaultID
        return BrowserProfileButtonPresence.resolve(
            alwaysShown: style != .quiet, colored: style == .color,
            personProfiles: ordered.lazy.filter { $0.id != AgentBrowserProfile.id }.count,
            incognito: services.cache.browserTabs.isIncognitoTab(key), agentsProfile: id == AgentBrowserProfile.id
        )
    }

    /// Re-renders every browser toolbar after a profile or a default changed. Tab strips follow by
    /// themselves: a pane snapshot reads `tabBadge` (observed: the book, the home records), so
    /// only the strips whose badge changed map again. Pushing every strip here re-ran every pane
    /// snapshot twice at each launch, with nothing changed (cx-8w027.23, I2).
    func refreshPresentation() {
        for (key, entry) in services.cache.browsers {
            entry.state.profileBadge = toolbarBadge(forTab: key)
            entry.state.profileName = BrowserToolbarHandlers.profileName(forTab: key, services: services)
        }
    }
}
