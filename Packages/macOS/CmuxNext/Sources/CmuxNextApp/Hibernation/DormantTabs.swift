import Observation

/// Tabs whose page is hibernated, observable so tab strips dim them
/// (`TabItem.isDormant`) the moment they hibernate or wake.
@MainActor
@Observable
final class DormantTabs {
    private(set) var ids: Set<String> = []

    func set(_ key: String, _ dormant: Bool) {
        if dormant {
            if !ids.contains(key) { ids.insert(key) }
        } else if ids.contains(key) {
            ids.remove(key)
        }
    }

    func contains(_ key: String) -> Bool { ids.contains(key) }
}
