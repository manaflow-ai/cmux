import CmuxNextSidebar

/// What a window's sidebar shows while its machines are still loading
/// (snapshot-first launch): the live sections, with each section that is
/// still loading and has no rows filled from the window's saved sidebar
/// (`SidebarRowState.stale`), or with placeholder rows when nothing was
/// saved. While the app is launching, saved sections the live sidebar
/// does not list yet (pinned, Cloud machines before the machine list
/// arrives) keep their place. A section that stopped loading spends its
/// saved rows, so they never come back later. A section given placeholders
/// at launch keeps them past the launch until its machine connects or
/// fails, so the end of the launch never empties it in between.
struct SidebarSeed {
    /// Placeholder rows in a loading section with nothing saved, shown from
    /// the launch only (never on a later Cloud reconnect).
    static let placeholderCount = 3

    private(set) var sections: [SidebarSection]
    /// Sections that showed placeholders at launch and have not stopped
    /// loading since.
    private var placeholderSections: Set<SectionID> = []

    init(sections: [SidebarSection] = []) {
        self.sections = sections
    }

    /// `live` with loading sections filled in. `launching` is true until the
    /// app restored its windows (or the local daemon is unavailable).
    /// `failed` lists machines whose first connection gave up while their
    /// header still says connecting: their placeholders end.
    mutating func merge(_ live: [SidebarSection], launching: Bool, failed: Set<MachineID> = []) -> [SidebarSection] {
        var result: [SidebarSection] = []
        for section in live {
            let loading = Self.isLoading(section, launching: launching)
            if !loading {
                sections.removeAll { $0.id == section.id }
                placeholderSections.remove(section.id)
            }
            if let machine = section.machine, failed.contains(machine.id) { placeholderSections.remove(section.id) }
            guard loading, section.workspaces.isEmpty else {
                result.append(section)
                continue
            }
            var filled = section
            if let saved = sections.first(where: { $0.id == section.id }) {
                filled.nodes = saved.nodes
            } else if let machine = section.machine, !failed.contains(machine.id),
                      launching || placeholderSections.contains(section.id) {
                if launching { placeholderSections.insert(section.id) }
                filled.nodes = Self.placeholders(machine: machine.id).map(SidebarNode.workspace)
            }
            result.append(filled)
        }
        let listed = Set(live.map(\.id))
        if launching {
            for (index, saved) in sections.enumerated() where !listed.contains(saved.id) {
                result.insert(saved, at: min(index, result.count))
            }
        } else {
            sections.removeAll { !listed.contains($0.id) }
            placeholderSections.formIntersection(listed)
        }
        return result
    }

    /// The local machine (and the pinned area, which holds its rows) loads
    /// until the launch ends; another machine while it connects.
    static func isLoading(_ section: SidebarSection, launching: Bool) -> Bool {
        guard let machine = section.machine else { return launching }
        return machine.kind == .local ? launching : machine.status == .connecting
    }

    /// Placeholder rows of machine `machine`; their ids never collide with
    /// a daemon workspace id.
    static func placeholders(machine: MachineID) -> [SidebarWorkspace] {
        (0..<placeholderCount).map { index in
            SidebarWorkspace(id: WorkspaceID("placeholder:\(machine.rawValue):\(index)"), machineID: machine, title: "",
                             rowState: .placeholder)
        }
    }

    /// `sections` with every live row marked `.stale` (the daemon's launch
    /// snapshot, before the live tree).
    static func stale(_ sections: [SidebarSection]) -> [SidebarSection] {
        sections.map { section in
            var section = section
            section.nodes = section.nodes.map { node in
                switch node {
                case var .workspace(ws):
                    ws.rowState = .stale
                    return .workspace(ws)
                case var .group(group):
                    group.workspaces = group.workspaces.map { ws in
                        var ws = ws
                        ws.rowState = .stale
                        return ws
                    }
                    return .group(group)
                }
            }
            return section
        }
    }
}
