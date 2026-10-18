import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs

/// How tabs and omnibars show their browser profile (data-model.md 5): the
/// omnibar names every tab's profile once more than one exists; a tab whose
/// profile differs from its workspace's shows a dot.
extension BrowserProfileService {
    /// The tab strip dot of `tab`, nil when its profile is the one its
    /// workspace gives new tabs.
    func tabBadge(for tab: TabModel, workspaceID: String?) -> TabProfileBadge? {
        let id = profileID(ofTab: tab)
        guard BrowserProfileCascade.showsTabBadge(tabProfile: id, workspaceEffective: effectiveProfile(forWorkspace: workspaceID)) else {
            return nil
        }
        let record = record(id)
        return TabProfileBadge(name: record?.name ?? displayName(id), color: record?.color.flatMap(GroupColor.init(rawValue:)))
    }

    /// The omnibar avatar of tab `key`: nil while one profile exists, and
    /// for incognito tabs (their window says incognito).
    func omnibarBadge(forTab key: String) -> BrowserProfileBadge? {
        guard BrowserProfileCascade.showsOmnibarBadge(profileCount: ordered.count),
              !services.cache.browserTabs.isIncognitoTab(key) else { return nil }
        let id = services.cache.tabModel(key).map(profileID(ofTab:)) ?? BrowserProfileRecord.defaultID
        let record = record(id)
        return BrowserProfileBadge(monogram: record?.monogram ?? "?", color: record?.color.flatMap(GroupColor.init(rawValue:)),
                                   name: record?.name ?? displayName(id))
    }

    /// Re-renders every omnibar after a profile or a default changed. Tab strips follow by
    /// themselves: a pane snapshot reads `tabBadge` (observed: the book, the home records), so
    /// only the strips whose badge changed map again. Pushing every strip here re-ran every pane
    /// snapshot twice at each launch, with nothing changed (cx-8w027.23, I2).
    func refreshPresentation() {
        for (key, entry) in services.cache.browsers {
            entry.chrome.addressBar.setProfileBadge(omnibarBadge(forTab: key))
            entry.chrome.toolbarButtons.profileName = BrowserToolbarHandlers.profileName(forTab: key, services: services)
        }
    }
}
