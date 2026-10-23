import Observation

/// The indexed tabs that carry a status fact (``TabModel/carriesStatusFact``): an agent hook
/// record, OSC 7501 program status records, a running shell command, or an agent session.
///
/// Only such a tab can report a status, so a reader that asks whether any tab of the tree works
/// (the keep-awake hold) reads these tabs alone, not every workspace, screen, pane and tab: a tab
/// added, closed, moved or reordered without a status fact wakes no such reader
/// (perf-lead.md cause 6). The set changes only when a tab gains or loses its last status fact,
/// or a tab that carries one comes into the tree or leaves it.
///
/// Kept by ``StoreIndex`` (a tab record is noted when indexed and dropped when its record goes)
/// and by the tab's own status writes (`TabModel.setAgent`, `applyState`, `update`).
@Observable @MainActor
public final class StatusFactTabs {
    /// The tabs that carry a status fact, by record identity.
    public private(set) var tabs: [ObjectIdentifier: TabModel] = [:]

    init() {}

    /// Every tab that carries a status fact, in no order.
    public var all: [TabModel] { Array(tabs.values) }

    /// `tab` was indexed or its status facts changed: it joins or leaves.
    func note(_ tab: TabModel) {
        let id = ObjectIdentifier(tab)
        let listed = tabs[id] != nil
        if tab.carriesStatusFact {
            if !listed { tabs[id] = tab }
        } else if listed {
            tabs[id] = nil
        }
    }

    /// `tab`'s record left the index.
    func drop(_ tab: TabModel) {
        let id = ObjectIdentifier(tab)
        if tabs[id] != nil { tabs[id] = nil }
    }
}
