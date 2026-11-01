/// What a window's sidebar shows while its machines are still loading
/// (snapshot-first launch): the live sections, with each section that is
/// still loading and has no rows filled from the window's saved sidebar
/// (`SidebarRowState.stale`), or, for another machine, with placeholder
/// rows when nothing was saved. While the app is launching, saved sections the live sidebar
/// does not list yet (pinned, Cloud machines before the machine list
/// arrives) keep their place. A section that stopped loading spends its
/// saved rows, so they never come back later. A section given placeholders
/// at launch keeps them through the launch grace period. Once the launch has
/// settled, an empty or unavailable machine section stays empty until live
/// workspaces arrive. The bars wait out `grace` first, so a machine that
/// connects at once never shows them.
public struct SidebarSeed {
    /// Placeholder rows in a loading section with nothing saved, shown from
    /// the launch only (never on a later Cloud reconnect).
    static let placeholderCount = 3

    public private(set) var sections: [SidebarSection]
    /// Once the launch has settled, a later reconnect must not resurrect the
    /// launch-only placeholder bars.
    private var settled = false
    /// A failed first connection is terminal for this seed. If a transient
    /// status callback still says `connecting`, it must not re-arm the bars.
    private var suppressedSections: Set<SectionID> = []
    public let grace: SidebarPlaceholderGrace
    /// Holds one list's "Connecting…" labels for the startup deadline (`holdingConnectingLabels`).
    public let connecting: SidebarPlaceholderGrace

    public init(sections: [SidebarSection] = [], grace: SidebarPlaceholderGrace = SidebarPlaceholderGrace(),
                connecting: SidebarPlaceholderGrace = SidebarPlaceholderGrace(wait: SidebarPlaceholderGrace.connectingDelay)) {
        self.sections = sections
        self.grace = grace
        self.connecting = connecting
    }

    /// `live` with loading sections filled in. `launching` is true until the
    /// app restored its windows (or the local daemon is unavailable).
    /// `failed` lists machines whose first connection gave up while their
    /// header still says connecting: their placeholders end and do not
    /// reappear during a later connecting callback.
    public mutating func merge(_ live: [SidebarSection], launching: Bool, failed: Set<MachineID> = []) -> [SidebarSection] {
        if !launching, !settled {
            settled = true
            // Cancel a pending grace callback before it can repopulate rows
            // from the launch-only projection.
            grace.keep([])
        }
        var result: [SidebarSection] = []
        for section in live {
            let loading = Self.isLoading(section, launching: launching)
            let machineFailed = section.machine.map { failed.contains($0.id) || $0.status.needsAttention } ?? false
            if machineFailed {
                suppressedSections.insert(section.id)
                grace.reset(section.id)
            }
            if !loading {
                sections.removeAll { $0.id == section.id }
                grace.reset(section.id)
            }
            guard loading, section.workspaces.isEmpty else {
                result.append(section)
                continue
            }
            var filled = section
            if let saved = sections.first(where: { $0.id == section.id }) {
                filled.nodes = saved.nodes
            } else if let machine = section.machine, machine.kind != .local, launching, !settled, !machineFailed,
                      !suppressedSections.contains(section.id) {
                // Only another machine shows placeholder bars: this Mac's daemon answers within the launch,
                // so its section stays empty until its rows come, never a loading look (Lawrence 2026-10-16).
                if grace.allows(section.id) { filled.nodes = Self.placeholders(machine: machine.id).map(SidebarNode.workspace) }
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
            grace.keep(listed)
        }
        return result
    }

    /// Whether a launch shows the sidebar now (`LaunchReveal`'s `.sidebar`): once `shown` has
    /// real rows, or when no saved rows stand in for them (a fresh profile, or a saved sidebar
    /// with no workspaces: what is drawn is what was saved), so a launch never draws glass
    /// alone where the sidebar goes.
    public func isReadyForReveal(_ shown: [SidebarSection], launching: Bool) -> Bool {
        !launching || sections.allSatisfy(\.workspaces.isEmpty) || shown.contains { $0.workspaces.contains { $0.rowState != .placeholder } }
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
}
