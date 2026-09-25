@testable import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSSH
import Foundation
import Testing

/// SSH workspace rows inside the shell store when other computers are live:
/// aggregation re-keys every row, and Mac lifecycle passes reconcile the
/// per-computer entries. Neither may break or drop SSH rows.
@MainActor
@Suite struct MobileSSHCompositeRowTests {
    private func makeStore() async throws -> (MobileShellComposite, SSHHostRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-rows-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        let host = SSHHostRecord(
            name: "tmux direct",
            endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody")
        )
        try await computers.saveHost(host)
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: MobileShellDemoContentTests.RecordingPairedMacStore(),
            identityProvider: StaticIdentityProvider(userID: "ssh-rows-user"),
            teamIDProvider: { "team-a" },
            sshComputers: computers
        )
        return (store, host)
    }

    /// One SSH computer's rows as its runtime publishes them (local ids are
    /// kind-encoded: `tmux:<session>`, `shell:<n>`).
    private func sshState(host: SSHHostRecord, sessions: [String]) -> MacWorkspaceState {
        let computerID = MobileSSHIdentifier(computerOf: host.id).rawValue
        return MacWorkspaceState(
            macDeviceID: computerID,
            displayName: host.name,
            workspaces: sessions.map { session in
                MobileWorkspacePreview(
                    id: .init(rawValue: MobileSSHIdentifier(host: host.id, local: session).rawValue),
                    macDeviceID: computerID,
                    name: session,
                    terminals: [
                        MobileTerminalPreview(
                            id: .init(rawValue: MobileSSHIdentifier(host: host.id, local: "\(session)/%1").rawValue),
                            name: "0:zsh"
                        ),
                    ]
                )
            },
            workspaceGroupsAreAuthoritative: true,
            status: .connected,
            workspaceSnapshotIsAuthoritative: true,
            actionCapabilities: MobileWorkspaceActionCapabilities(supportsCloseActions: true)
        )
    }

    private func macState() -> MacWorkspaceState {
        MacWorkspaceState(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            workspaces: [MobileWorkspacePreview(id: "ws-1", macDeviceID: "mac-a", name: "Mac workspace", terminals: [])],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )
    }

    /// With a Mac and a second SSH computer live, aggregation re-keys the
    /// tmux row as `cmux-ssh-<host><US>cmux-ssh-<host>~vt-main`. That id
    /// still starts with the SSH prefix but no longer parses, which hid
    /// "New Terminal" for every tmux workspace. The row must resolve to its
    /// scoped id and keep terminal tabs.
    @Test func tmuxRowKeepsNewTerminalWhenSeveralComputersAreLive() async throws {
        let (store, host) = try await makeStore()
        let other = SSHHostRecord(name: "other", endpoint: SSHEndpoint(host: "127.0.0.2", port: 1, username: "nobody"))
        store.setWorkspaceStatesForTesting(["mac-a": macState()], foregroundMacDeviceID: "mac-a")
        store.sshPublishWorkspaceState(sshState(host: host, sessions: ["tmux:vt-main"]))
        store.sshPublishWorkspaceState(sshState(host: other, sessions: ["tmux:cmux-1"]))

        let scoped = MobileSSHIdentifier(host: host.id, local: "tmux:vt-main").rawValue
        let row = try #require(store.workspaces.first { $0.rpcWorkspaceID.rawValue == scoped })
        // Aggregation is live: the row id is re-keyed and does not parse.
        #expect(row.id.rawValue != scoped)
        #expect(MobileSSHIdentifier(row.id.rawValue).isSSH)
        #expect(MobileSSHIdentifier(row.id.rawValue).hostID == nil)

        #expect(store.sshOwnsWorkspaceRow(row.id))
        #expect(store.sshScopedWorkspaceID(row.id) == scoped)
        #expect(store.sshSupportsTerminalTabs(workspaceID: row.id))
        // The Mac row is not an SSH row.
        let macRow = try #require(store.workspaces.first { $0.macDeviceID == "mac-a" })
        #expect(store.sshScopedWorkspaceID(macRow.id) == nil)
    }

    /// A shell row still reports no terminal tabs through the same
    /// re-keyed id (the fix must not make every SSH row tab-capable), while
    /// a tmux row on the same host keeps them: tabs follow the row's kind.
    @Test func shellRowHasNoTerminalTabsWhenSeveralComputersAreLive() async throws {
        let (store, host) = try await makeStore()
        store.setWorkspaceStatesForTesting(["mac-a": macState()], foregroundMacDeviceID: "mac-a")
        store.sshPublishWorkspaceState(sshState(host: host, sessions: ["shell:1", "tmux:work"]))
        let tmuxRow = try #require(store.workspaces.first {
            $0.rpcWorkspaceID.rawValue == MobileSSHIdentifier(host: host.id, local: "tmux:work").rawValue
        })
        #expect(store.sshSupportsTerminalTabs(workspaceID: tmuxRow.id))
        #expect(store.sshWorkspaceKind(workspaceID: tmuxRow.id) == .tmux)
        let scoped = MobileSSHIdentifier(host: host.id, local: "shell:1").rawValue
        let row = try #require(store.workspaces.first { $0.rpcWorkspaceID.rawValue == scoped })
        #expect(store.sshScopedWorkspaceID(row.id) == scoped)
        #expect(!store.sshSupportsTerminalTabs(workspaceID: row.id))
        #expect(store.sshWorkspaceKind(workspaceID: row.id) == .shell)
    }

    @Test func scopedIDsParseAndAggregatedIDsDoNot() {
        let host = UUID()
        let scoped = MobileSSHIdentifier(host: host, local: "vt-main").rawValue
        #expect(MobileSSHIdentifier(scoped).isScoped)
        #expect(!MobileSSHIdentifier(computerOf: host).isScoped)
        #expect(!MobileSSHIdentifier(MobileSSHIdentifier(computerOf: host).rawValue + "\u{1F}" + scoped).isScoped)
    }

    /// A full secondary-Mac reconcile (foreground, Computers sheet, presence
    /// churn) pruned every per-computer entry that was not a stored paired
    /// Mac, which removed SSH rows until the next SSH pull-to-refresh: the
    /// workspace list read "No tmux Sessions" after `+` then Back.
    @Test func secondaryReconcileKeepsSSHRows() async throws {
        let (store, host) = try await makeStore()
        store.sshPublishWorkspaceState(sshState(host: host, sessions: ["cmux-1", "vt-main"]))
        let computerID = MobileSSHIdentifier(computerOf: host.id).rawValue
        #expect(store.workspaces.filter { $0.macDeviceID == computerID }.count == 2)

        await store.refreshSecondaryMacWorkspaces()

        #expect(store.workspaces.filter { $0.macDeviceID == computerID }.count == 2)
        #expect(store.workspaces.first { $0.macDeviceID == computerID }?.macConnectionStatus == .connected)
    }

    /// An outage downgrade of the Macs leaves SSH computers' own status alone.
    @Test func macOutageDoesNotMarkSSHComputerUnavailable() async throws {
        let (store, host) = try await makeStore()
        store.setWorkspaceStatesForTesting(["mac-a": macState()], foregroundMacDeviceID: "mac-a")
        store.sshPublishWorkspaceState(sshState(host: host, sessions: ["vt-main"]))
        store.markSecondaryMacUnavailableForTesting(MobileSSHIdentifier(computerOf: host.id).rawValue)
        let computerID = MobileSSHIdentifier(computerOf: host.id).rawValue
        #expect(store.workspaces.first { $0.macDeviceID == computerID }?.macConnectionStatus == .connected)
    }
}

/// Listing results and status recovery in the SSH runtime.
@MainActor
@Suite struct MobileSSHRefreshTests {
    /// A provider whose listings are released one at a time by the test.
    @MainActor
    final class GatedProvider: MobileSSHWorkspaceProvider {
        private var waiting: [CheckedContinuation<[MobileSSHWorkspace], Never>] = []
        var pendingListings: Int { waiting.count }

        func listWorkspaces() async throws -> [MobileSSHWorkspace] {
            await withCheckedContinuation { waiting.append($0) }
        }

        /// Answers the oldest pending listing.
        func releaseOldest(with sessions: [String]) {
            waiting.removeFirst().resume(returning: sessions.map { MobileSSHWorkspace(id: $0, name: $0, terminals: []) })
        }

        /// Answers the newest pending listing.
        func releaseNewest(with sessions: [String]) {
            waiting.removeLast().resume(returning: sessions.map { MobileSSHWorkspace(id: $0, name: $0, terminals: []) })
        }

        func createWorkspace() async throws -> MobileSSHWorkspace { throw CancellationError() }
        func closeWorkspace(id: String) async throws {}
        func attach(
            terminalID: String,
            columns: Int,
            rows: Int,
            events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
        ) async throws -> any MobileSSHAttachedTerminal {
            throw CancellationError()
        }
    }

    private func makeRuntime() async throws -> (MobileSSHComputers, RecordingSSHSink, SSHHostRecord, GatedProvider) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-refresh-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        let sink = RecordingSSHSink()
        computers.sink = sink
        let host = SSHHostRecord(
            name: "tmux direct",
            endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody")
        )
        try await computers.saveHost(host)
        let provider = GatedProvider()
        computers.installProviderForTesting(provider, hostID: host.id)
        return (computers, sink, host, provider)
    }

    private func waitForListings(_ provider: GatedProvider, _ count: Int) async {
        while provider.pendingListings < count { await Task.yield() }
    }

    /// tmux was missing (status failed with its reason); after it is
    /// installed, pull-to-refresh lists sessions over the same connection.
    /// The host must read connected again: no "Not Connected" title, no
    /// "Disconnected" rows, no stale reason under the list.
    @Test func successfulRefreshAfterAFailureReportsConnected() async throws {
        let (computers, sink, host, provider) = try await makeRuntime()
        computers.failForTesting(hostID: host.id, MobileSSHRuntimeError.tmuxMissing)
        #expect(computers.statusByHost[host.id] == .failed(L10nSSH().tmuxMissing))
        #expect(sink.states.last?.status == .unavailable)

        let open = Task { await computers.open(hostID: host.id) }
        await waitForListings(provider, 1)
        provider.releaseOldest(with: ["tmissprobe"])
        await open.value

        #expect(computers.statusByHost[host.id] == .connected)
        let state = try #require(sink.states.last)
        #expect(state.status == .connected)
        #expect(state.workspaces.map(\.name) == ["tmissprobe"])
    }

    /// A slow listing that started before a newer one (a create's refresh)
    /// must not replace the newer result when it finally lands.
    @Test func olderListingNeverReplacesANewerOne() async throws {
        let (computers, sink, host, provider) = try await makeRuntime()
        let older = Task { await computers.refreshWorkspaces(hostID: host.id) }
        await waitForListings(provider, 1)
        let newer = Task { await computers.refreshWorkspaces(hostID: host.id) }
        await waitForListings(provider, 2)

        // The newer listing (after `+`) lands first; the older one, which
        // predates the new session, lands last and must be ignored.
        provider.releaseNewest(with: ["cmux-1", "vt-main"])
        await newer.value
        provider.releaseOldest(with: [])
        await older.value
        #expect(sink.states.last?.workspaces.map(\.name) == ["cmux-1", "vt-main"])
    }

    /// The list reappearing relists connected hosts only.
    @Test func refreshIfConnectedSkipsHostsWithoutAProvider() async throws {
        let (computers, _, host, provider) = try await makeRuntime()
        computers.refreshIfConnected(hostID: UUID())
        computers.refreshConnectedHosts()
        await waitForListings(provider, 1)
        provider.releaseOldest(with: ["vt-main"])
        #expect(provider.pendingListings == 0)
        _ = host
    }
}
