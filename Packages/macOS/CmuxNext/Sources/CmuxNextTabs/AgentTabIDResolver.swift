/// Finds the machine of a tab id given alone (`AgentTabStore.tabKey(_:machine: nil)`).
///
/// A key press asks this for the selected tab (Cmd-T's `isAgentTab(selected)`, the key router, the
/// strip, the toolbar), also for a terminal and a browser, so every step is an index read: the
/// state maps' id index (`AgentTabMap.keys(ofTab:)`) and each machine's own tab index (`listed`).
/// It never walks the session's tab list: that made one key press cost O(session) (#36767).
public struct AgentTabIDResolver {
    /// A provisional id's real id on its machine, for the creations not settled yet (`rekey`).
    private let aliases: AgentTabMap<String>

    public init(aliases: AgentTabMap<String>) {
        self.aliases = aliases
    }

    /// The key of tab id `id`: the one machine that has agent state for it, else the one machine
    /// whose tree lists it as an agent tab, else no machine (`""`: none, or more than one).
    /// - Parameters:
    ///   - held: the keys with id `id` that have agent state (a page, a session, a followed store).
    ///   - holds: whether a key has agent state.
    ///   - listed: the agent tab with the given id on each machine whose tree lists one.
    public func key(of id: String, held: [AgentTabKey], holds: (AgentTabKey) -> Bool, listed: (String) -> [AgentTabKey]) -> AgentTabKey {
        // State under the id, or under the id that `id` became on a machine.
        var candidates = Set(held)
        for alias in aliases.keys(ofTab: id) {
            guard let real = aliases[alias] else { continue }
            let scoped = AgentTabKey(machine: alias.machine, key: real)
            if holds(scoped) { candidates.insert(scoped) }
        }
        if candidates.count == 1, let only = candidates.first { return only }
        guard candidates.isEmpty else { return AgentTabKey(machine: "", key: resolve(id)) }
        // No state yet: the machines whose tree lists the tab, under `id` or under the provisional
        // id that `id` replaced there.
        candidates.formUnion(listed(id))
        for (alias, real) in aliases where real == id && listed(alias.key).contains(alias) { candidates.insert(alias) }
        if candidates.count == 1, let only = candidates.first { return only }
        return AgentTabKey(machine: "", key: resolve(id))
    }

    /// The real id of `id` when one machine has an alias for it, else `id`.
    public func resolve(_ id: String) -> String {
        aliases.onlyKey(ofTab: id).flatMap { aliases[$0] } ?? id
    }
}
