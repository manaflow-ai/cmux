public import CmuxNextDaemon

/// Per-tab agent state the app's tab content cache owns: tabs an agent drove, surfaces an
/// agent opened (claimed when their tab arrives), browser splits an agent asked for (by their
/// new pane), and tabs where the person allowed agents despite extension access
/// (plans/cmux-next/passwords.md, section 3.4). Everything for a tab ends when the tab closes.
public struct TabAgentMarks {
    public var tabs: Set<String> = []
    public var surfaces: Set<SurfaceID> = []
    public var extensionOverrides: Set<String> = []
    /// Marked panes, each with the surfaces it has claimed so far.
    private var panes: [String: Set<SurfaceID>] = [:]

    public init() {}

    public mutating func forget(_ key: String) {
        tabs.remove(key)
        extensionOverrides.remove(key)
    }

    /// A browser split an agent asked for (Insert New at a divider from the CLI, MCP or a script), by
    /// the new pane's client-minted id (`pane_<32 hex>`) on `machine`: the split's stand-in tab and
    /// then the daemon's tab both show in that pane before any reply names a surface, so the mark
    /// claims both pages before they exist. Until the reply (``settle(pane:machine:surface:)``) it marks
    /// every new tab of the pane, so a tab the person opens there first can only lose saved-password
    /// fill, never take the mark from the agent's tab (review of #37733).
    public mutating func mark(pane: String, machine: String) { panes[Self.paneKey(machine, pane)] = [] }

    /// The daemon answered the split marked for `pane`: `surface` is the agent's tab, or nil when the
    /// split was refused or failed. The pane mark ends; a tab of `surface` that has not claimed it
    /// yet is marked by its surface.
    public mutating func settle(pane: String, machine: String, surface: SurfaceID?) {
        guard let claimed = panes.removeValue(forKey: Self.paneKey(machine, pane)) else { return }
        if let surface, !claimed.contains(surface) { surfaces.insert(surface) }
    }

    /// Tab `key` (surface `surface`, in pane `pane` of `machine`) is about to get a page: it is an agent's
    /// when an agent opened its surface or asked for its split, and it has no page yet (`hasPage`).
    public mutating func claim(surface: SurfaceID, key: String, pane: String?, machine: String, hasPage: Bool) {
        let paneKey = pane.map { Self.paneKey(machine, $0) }
        let byPane = paneKey.map { panes[$0] != nil } ?? false
        guard surfaces.remove(surface) != nil || byPane, !hasPage else { return }
        if byPane, let paneKey { panes[paneKey]?.insert(surface) }
        tabs.insert(key)
    }

    private static func paneKey(_ machine: String, _ pane: String) -> String { machine + "\u{1F}" + pane }
}
