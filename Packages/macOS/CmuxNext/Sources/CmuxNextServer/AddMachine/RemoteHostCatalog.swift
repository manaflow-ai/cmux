import Foundation

/// The hosts New Remote Group's Cmd-Shift-P step lists (remote-groups-DESIGN.md slice E): the
/// app's machines, online Tailscale peers and `~/.ssh/config` aliases (``RemoteHostChoice/merge(connected:tailnet:sshAliases:)``).
///
/// The palette asks synchronously, so peers and aliases are cached: each ask returns the cache and,
/// when it is older than ``maxAge``, starts one refresh in the background; the next ask has it.
///
/// ```swift
/// let catalog = RemoteHostCatalog(connected: { machines.ssh.map(\.host.destination.description) },
///                                 peers: { await cli?.candidates(probe: false).flatMap { try? HostCandidate.parseList($0) } },
///                                 aliases: { await readAliases() })
/// catalog.choices() // [mini · Connected, studio · Tailscale, linux-vm · SSH config]
/// ```
@MainActor public final class RemoteHostCatalog {
    /// How long a refresh stays fresh.
    public static let maxAge: Duration = .seconds(60)

    private let connected: @MainActor () -> [String]
    private let peers: @Sendable () async -> [HostCandidate]?
    private let aliases: @Sendable () async -> [String]
    private let now: () -> ContinuousClock.Instant
    private var tailnet: [HostCandidate] = []
    private var sshAliases: [String] = []
    private var refreshedAt: ContinuousClock.Instant?
    private var refresh: Task<Void, Never>?

    /// - Parameters:
    ///   - connected: the destinations of the app's machines, read on each ask.
    ///   - peers: the tailnet peers (`cmux-tui acp host candidates --json`); nil keeps the last list.
    ///   - aliases: the `~/.ssh/config` aliases (``SSHConfigHosts/aliases(in:home:)`` on a blocking lane).
    ///   - now: the current instant; tests pass a fixed one.
    public init(connected: @escaping @MainActor () -> [String],
                peers: @escaping @Sendable () async -> [HostCandidate]?,
                aliases: @escaping @Sendable () async -> [String],
                now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.connected = connected
        self.peers = peers
        self.aliases = aliases
        self.now = now
    }

    /// The hosts to offer now; starts a background refresh when the cache is stale.
    public func choices() -> [RemoteHostChoice] {
        refreshIfStale()
        return RemoteHostChoice.merge(connected: connected(), tailnet: tailnet, sshAliases: sshAliases)
    }

    /// Refreshes peers and aliases and waits for it (the first ask's list; tests).
    public func reload() async {
        refreshIfStale(force: true)
        await refresh?.value
    }

    private func refreshIfStale(force: Bool = false) {
        guard refresh == nil else { return }
        if !force, let refreshedAt, now() - refreshedAt < Self.maxAge { return }
        let peers = self.peers, aliases = self.aliases
        // task-owner: one bounded peer listing (the CLI's 15 s deadline) and one config read; cleared when done.
        refresh = Task { [weak self] in
            async let list = peers()
            async let names = aliases()
            let (peerList, aliasList) = await (list, names)
            guard let self else { return }
            if let peerList { self.tailnet = peerList }
            self.sshAliases = aliasList
            self.refreshedAt = self.now()
            self.refresh = nil
        }
    }
}
