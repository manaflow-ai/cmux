import Foundation

/// Which agent drives which app browser tab through `browser.page.right`,
/// so two agents never drive one tab (plans/cmux-next/chief-browser-use-DESIGN.md).
///
/// A lease names its agent and lapses `ttl` after the agent last resolved
/// the tab, so an agent that stopped without `release` frees it. Each agent
/// also remembers the tab it opened, which it gets back first.
actor BrowserTabLeases {
    private struct Lease {
        var agent: String
        var expires: ContinuousClock.Instant
    }

    private var leases: [String: Lease] = [:]
    private var opened: [String: String] = [:]
    /// The tab each agent's work shows in Home's right column (one per agent).
    private var homeMirrors: [String: String] = [:]
    private let ttl: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    /// - Parameters:
    ///   - ttl: how long a lease outlives the agent's last use (default 5 minutes:
    ///     longer than one Chief turn's pauses, short enough that a stopped Chief frees the tab).
    ///   - now: the clock; tests pass a fixed one.
    init(ttl: Duration = .seconds(300), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.ttl = ttl
        self.now = now
    }

    /// The tab `agent` opened, if it still names one of `tabs`.
    func openedTab(of agent: String, among tabs: Set<String>) -> String? {
        guard let tab = opened[agent], tabs.contains(tab) else { return nil }
        return tab
    }

    /// A tab of `tabs` on which `agent` holds a live lease (the first in `tabs` order).
    func heldTab(of agent: String, among tabs: [String]) -> String? {
        let instant = now()
        return tabs.first { leases[$0].map { $0.agent == agent && $0.expires > instant } ?? false }
    }

    /// Gives `tab` to `agent` (renewing its lease) unless another agent's
    /// lease on it has not lapsed; returns that agent then, nil once claimed.
    /// `opened` records the tab as the agent's own. One step, so two agents
    /// asking at once never both get the tab.
    /// `lasting` replaces `ttl` for this claim (a direct verb's shorter lease);
    /// a renewal never shortens a lease the agent already holds.
    func acquire(_ tab: String, for agent: String, opened isOwn: Bool = false, lasting: Duration? = nil) -> String? {
        let instant = now()
        if let lease = leases[tab], lease.agent != agent, lease.expires > instant { return lease.agent }
        var expires = instant + (lasting ?? ttl)
        if let lease = leases[tab], lease.agent == agent, lease.expires > expires { expires = lease.expires }
        leases[tab] = Lease(agent: agent, expires: expires)
        if isOwn { opened[agent] = tab }
        return nil
    }

    /// The agent whose lease on `tab` has not lapsed, if any.
    func holder(of tab: String) -> String? {
        guard let lease = leases[tab], lease.expires > now() else { return nil }
        return lease.agent
    }

    /// Records `tab` as `agent`'s Home mirror (``BrowserPageService/mirrorIntoHome(_:for:call:mirrors:leases:)``);
    /// returns the tab it mirrored before, if any.
    func noteHomeMirror(_ tab: String, for agent: String) -> String? {
        defer { homeMirrors[agent] = tab }
        return homeMirrors[agent]
    }

    /// Drops every lease `agent` holds and forgets its tab; returns the tabs it held.
    func release(_ agent: String) -> [String] {
        let held = leases.filter { $0.value.agent == agent }.map(\.key).sorted()
        for tab in held { leases[tab] = nil }
        opened[agent] = nil
        return held
    }
}
