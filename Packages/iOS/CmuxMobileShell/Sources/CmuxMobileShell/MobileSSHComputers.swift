import CMUXMobileCore
internal import CmuxMobileTerminalKit
internal import CryptoKit
internal import LocalAuthentication
internal import Network
internal import CmuxMobileSupport
public import CmuxMobileSSH
public import CmuxMobileShellModel
public import Foundation
public import Observation

/// A question the SSH runtime needs the user to answer before a connection
/// can continue. The UI presents one at a time and resolves it.
public enum MobileSSHPrompt: Identifiable, Sendable {
    /// First connection to a host: trust this identity key? (TOFU)
    case trustNewHostKey(host: SSHHostRecord, key: SSHHostKey)
    /// The pinned identity key changed: stop and ask (PRD D17).
    case hostKeyChanged(host: SSHHostRecord, pinned: SSHHostKey, presented: SSHHostKey)

    /// The host an identity question (new or changed server key) is about.
    public var identityHostID: UUID? {
        switch self {
        case .trustNewHostKey(let host, _), .hostKeyChanged(let host, _, _): host.id
        }
    }

    public var id: String {
        switch self {
        case .trustNewHostKey(let host, _): "trust-\(host.id)"
        case .hostKeyChanged(let host, _, _): "changed-\(host.id)"
        }
    }

    /// Whether answering `self` also answers `other`: same host, address,
    /// and keys.
    func asksSameQuestion(as other: MobileSSHPrompt) -> Bool {
        switch (self, other) {
        case let (.trustNewHostKey(host, key), .trustNewHostKey(otherHost, otherKey)):
            host.id == otherHost.id && host.endpoint == otherHost.endpoint && key == otherKey
        case let (.hostKeyChanged(host, pinned, presented), .hostKeyChanged(otherHost, otherPinned, otherPresented)):
            host.id == otherHost.id && host.endpoint == otherHost.endpoint
                && pinned == otherPinned && presented == otherPresented
        default:
            false
        }
    }
}

/// Connection state of one SSH computer, shown on its Computers row.
public enum MobileSSHHostStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed(String)
}

/// Receives SSH runtime effects on the shell store.
@MainActor
protocol MobileSSHComputersSink: AnyObject {
    func sshPublishWorkspaceState(_ state: MacWorkspaceState)
    func sshRemoveWorkspaceState(computerID: String)
    /// Replaces the surface contents (clear + bytes) or appends bytes.
    func sshDeliver(_ bytes: Data, surfaceID: String)
    /// The surface's fixed remote grid changed (``MobileSSHComputers/remoteGrid(surfaceID:)``).
    func sshApplyViewport(surfaceID: String)
    /// Replaces the streamable browser tabs of one SSH workspace row.
    func sshReplaceBrowserPanels(workspaceID: String, with descriptors: [MobileBrowserPanelDescriptor])
    func sshDeliverBrowserFrame(_ event: MobileBrowserFrameEvent)
    func sshDeliverBrowserState(_ event: MobileBrowserStateEvent)
    /// A browser stream ended without the phone asking (tab closed or
    /// transport lost). `retry` is false when the stream never showed a
    /// frame, so a server that keeps refusing cannot cause a reattach loop.
    func sshBrowserStreamEnded(panelID: String, retry: Bool)
}

/// Owns everything about SSH computers (PRD `docs/prd/ios-direct-ssh.md`):
/// saved hosts and keys, live connections, the per-host registry of
/// workspace kinds (cmux-tui, tmux, shell; PRD D31), and the terminal
/// attachments behind each SSH surface.
///
/// SSH computers render through the shell's ordinary per-computer stores,
/// like the demonstration computer: each host publishes one
/// ``MacWorkspaceState`` keyed by ``MobileSSHIdentifier/init(computerOf:)``,
/// and surface output enters the same per-surface output stream a Mac's
/// bytes use. Works without a cmux account (PRD D5).
@MainActor
@Observable
public final class MobileSSHComputers {
    public let hostStore: SSHHostStore
    public let keyStore: SSHKeyStore
    public private(set) var hosts: [SSHHostRecord] = []
    public private(set) var keys: [SSHKeyRecord] = []
    public private(set) var statusByHost: [UUID: MobileSSHHostStatus] = [:]
    /// Questions waiting for the user, oldest first.
    public private(set) var prompts: [MobileSSHPrompt] = []
    /// Which workspace kinds each connected host can create (PRD D31).
    /// Absent until the host is probed.
    public private(set) var kindAvailabilityByHost: [UUID: [MobileSSHKindAvailability]] = [:]
    /// Hosts uploading cmux-tui for their first cmux-tui workspace (D10).
    public private(set) var installingCmuxTUIHosts: Set<UUID> = []

    @ObservationIgnored weak var sink: (any MobileSSHComputersSink)?
    @ObservationIgnored private var connections: [UUID: SSHConnection] = [:]
    @ObservationIgnored private var connectTasks: [UUID: Task<SSHConnection, any Error>] = [:]
    @ObservationIgnored private var providers: [UUID: MobileSSHHostProviders] = [:]
    @ObservationIgnored private var workspacesByHost: [UUID: [MobileSSHWorkspace]] = [:]
    /// Bumped per listing started, so only the newest listing publishes.
    @ObservationIgnored private var refreshGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored private var attachments: [String: any MobileSSHAttachedTerminal] = [:]
    @ObservationIgnored private var attachTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var gridBySurface: [String: (columns: Int, rows: Int)] = [:]
    /// The last queued resize or geometry release per surface.
    @ObservationIgnored private var sizingTasks: [String: Task<Void, Never>] = [:]
    /// Input typed while a surface's attach is in flight.
    @ObservationIgnored private var pendingInputBySurface: [String: Data] = [:]
    /// Fixed grids of surfaces that do not own their PTY size (tmux panes).
    @ObservationIgnored private var remoteGridBySurface: [String: (columns: Int, rows: Int)] = [:]
    /// Recent output per surface so a remounted view repaints without asking
    /// the server. Capped; cmux-tui re-sends a snapshot on reattach anyway.
    @ObservationIgnored private var replayBySurface: [String: Data] = [:]
    /// Live browser attachments by scoped panel id (D23).
    @ObservationIgnored private var browserSessions: [String: any MobileSSHAttachedBrowser] = [:]
    /// Latest page metadata per panel, for descriptors built between events.
    @ObservationIgnored private var browserPageSize: [String: (width: Double, height: Double)] = [:]
    @ObservationIgnored private var browserMetadata: [String: MobileBrowserStateEvent] = [:]
    /// Panels whose current stream has delivered at least one frame.
    @ObservationIgnored private var browserPanelsWithFrames: Set<String> = []
    @ObservationIgnored private var publishedBrowserPanels: [String: [MobileBrowserPanelDescriptor]] = [:]
    /// Everyone waiting on each on-screen prompt. Connections that ask the
    /// same question at once (the editor's password install and the saved
    /// host's auto-connect) share one prompt and one answer.
    @ObservationIgnored private var promptContinuations: [String: [CheckedContinuation<MobileSSHPromptAnswer, Never>]] = [:]
    /// Hosts that stay manual until the user connects them again: the user
    /// disconnected them or declined a first-connect question.
    @ObservationIgnored private var autoConnectSuppressed: Set<UUID> = []
    @ObservationIgnored private var autoConnectTasks: [UUID: Task<Void, Never>] = [:]
    /// The latest queued write of a host's persisted auto-connect pause flag.
    @ObservationIgnored private var autoConnectPauseWrite: Task<Void, Never>?
    /// Counts pause-flag changes per host so only the newest write restores
    /// the in-memory flag.
    @ObservationIgnored private var autoConnectPauseGeneration: [UUID: Int] = [:]
    static let replayCap = 4 * 1_024 * 1_024

    public init(directory: URL) {
        hostStore = SSHHostStore(directory: directory)
        keyStore = SSHKeyStore(directory: directory)
        Task { await reload() }
    }

    /// Re-reads hosts and keys from disk and republishes every host's rows.
    public func reload() async {
        hosts = await hostStore.all()
        keys = await keyStore.all()
        for host in hosts { publish(host: host) }
    }

    // MARK: Host and key management

    /// Persists a host. When an existing host's connection details changed
    /// (address, user, key, jump host), its live connection closes and any
    /// failure from the old details clears, so the next connect uses the new
    /// ones. Does not connect; see ``saveHostAndConnect(_:)``.
    public func saveHost(_ host: SSHHostRecord) async throws {
        let previous = self.host(id: host.id)
        try await hostStore.upsert(host)
        if let previous, !previous.connectsLike(host) {
            await closeConnection(hostID: host.id)
        }
        await reload()
    }

    /// Saves a host from its form and connects it the way a paired Mac
    /// connects once added: a new host, or one whose connection details
    /// changed, starts ``autoConnect(hostID:)``. Editing only its name or
    /// idle policy leaves its connection (or a user's disconnect) alone.
    ///
    /// Saving new details is an explicit request to use them, so it lifts a
    /// disconnect or declined question left from the old details, like
    /// ``open(hostID:)``. A workspace list opened on the host meanwhile joins
    /// this connect instead of asking its questions again.
    @discardableResult
    public func saveHostAndConnect(_ host: SSHHostRecord) async throws -> Task<Void, Never>? {
        let previous = self.host(id: host.id)
        try await saveHost(host)
        if let previous, previous.connectsLike(host) { return nil }
        autoConnectSuppressed.remove(host.id)
        setAutoConnectPaused(false, hostID: host.id)
        return autoConnect(hostID: host.id)
    }

    public func deleteHost(id: UUID) async throws {
        await disconnect(hostID: id)
        try await hostStore.delete(id: id)
        sink?.sshRemoveWorkspaceState(computerID: MobileSSHIdentifier(computerOf: id).rawValue)
        await reload()
    }

    public func generateKey(label: String, requiresBiometry: Bool) async throws -> SSHKeyRecord {
        let record = try await keyStore.generateSecureEnclaveKey(label: label, requiresBiometry: requiresBiometry)
        keys = await keyStore.all()
        return record
    }

    public func importKey(label: String, privateKeyText: String, passphrase: String?) async throws -> SSHKeyRecord {
        let record = try await keyStore.importKey(label: label, privateKeyText: privateKeyText, passphrase: passphrase)
        keys = await keyStore.all()
        return record
    }

    public func deleteKey(id: UUID) async throws {
        try await keyStore.delete(id: id)
        keys = await keyStore.all()
    }

    /// Installs the host's key with a one-time password (PRD D16).
    public func installKey(hostID: UUID, password: String) async throws {
        guard let host = hosts.first(where: { $0.id == hostID }), let keyID = host.keyID,
              let record = await keyStore.record(id: keyID) else {
            throw SSHConnectionError.authenticationFailed
        }
        let key = try await keyStore.privateKey(for: keyID)
        let jump = try await jumpConnection(for: host)
        _ = try await SSHKeyInstaller().install(
            publicKeyLine: record.publicKeyLine,
            endpoint: host.endpoint,
            password: password,
            verifyWith: .privateKey(key),
            hostKeyVerifier: verifier(for: host),
            via: jump
        )
        // A connect that ran before the key existed left its refusal as the
        // host's status; the key works now, so drop it and connect with it.
        if case .failed = statusByHost[hostID] {
            statusByHost[hostID] = .idle
            publish(host: host)
        }
        autoConnect(hostID: hostID)
    }

    // MARK: Prompts

    /// Resolves the oldest matching prompt.
    ///
    /// Declining an identity question (a new or a changed server key) pauses
    /// automatic connects for that host, persistently, so reopening the app
    /// or its list does not ask again. Only an explicit connect
    /// (``open(hostID:)``) resumes them.
    ///
    /// An answer for a question that is no longer pending (already answered,
    /// or replaced by a question about another key) is ignored: the prompt
    /// sheet's binding writes a Cancel for the prompt it last rendered as it
    /// dismisses after a Trust, and that must not pause the host.
    public func answer(_ prompt: MobileSSHPrompt, with answer: MobileSSHPromptAnswer) {
        guard let pending = prompts.first(where: { $0.id == prompt.id }), pending.asksSameQuestion(as: prompt) else {
            return
        }
        prompts.removeAll { $0.id == prompt.id }
        if answer != .trust, let hostID = prompt.identityHostID {
            setAutoConnectPaused(true, hostID: hostID)
        }
        for waiter in promptContinuations.removeValue(forKey: prompt.id) ?? [] {
            waiter.resume(returning: answer)
        }
    }

    func ask(_ prompt: MobileSSHPrompt) async -> MobileSSHPromptAnswer {
        await withCheckedContinuation { continuation in
            if let pending = prompts.first(where: { $0.id == prompt.id }), pending.asksSameQuestion(as: prompt),
               promptContinuations[prompt.id] != nil {
                promptContinuations[prompt.id, default: []].append(continuation)
                return
            }
            // A different question under the same id (another key for this
            // host) replaces the stale one; its answer must not carry over.
            for stale in promptContinuations.removeValue(forKey: prompt.id) ?? [] {
                stale.resume(returning: .cancel)
            }
            promptContinuations[prompt.id] = [continuation]
            prompts.removeAll { $0.id == prompt.id }
            prompts.append(prompt)
        }
    }

    // MARK: Connections

    /// Connects (if needed), probes the host's workspace kinds, and
    /// refreshes its workspace rows. An explicit open re-enables automatic
    /// reconnects for the host.
    public func open(hostID: UUID) async {
        autoConnectSuppressed.remove(hostID)
        // The user asked for this connection, so identity questions may be
        // asked again: for the host and for the jump host it tunnels through.
        setAutoConnectPaused(false, hostID: hostID)
        if let jumpID = host(id: hostID)?.jumpHostID {
            setAutoConnectPaused(false, hostID: jumpID)
        }
        // Join an automatic connect already in flight rather than racing it
        // through the same first-connect questions.
        if let pending = autoConnectTasks[hostID] { await pending.value }
        await connectAndList(hostID: hostID)
    }

    /// Whether ``autoConnect(hostID:)`` would start a connection: the host
    /// exists, nothing is live or in flight, it did not fail (failures keep
    /// Retry), and the user did not disconnect it or decline a question
    /// (identity declines persist across launches, including a declined
    /// jump host).
    public func canAutoConnect(hostID: UUID) -> Bool {
        guard let host = host(id: hostID), !host.isAutoConnectPaused else { return false }
        if let jumpID = host.jumpHostID, self.host(id: jumpID)?.isAutoConnectPaused == true { return false }
        return (statusByHost[hostID] ?? .idle) == .idle
            && connections[hostID] == nil
            && connectTasks[hostID] == nil
            && autoConnectTasks[hostID] == nil
            && !autoConnectSuppressed.contains(hostID)
    }

    /// Connects a host the user is looking at, the way a paired Mac
    /// reconnects: when its workspace list appears, when the app returns to
    /// the foreground, and after its connection drops. Idempotent; a no-op
    /// unless ``canAutoConnect(hostID:)``. The runtime owns the work, so a
    /// view disappearing mid-connect never cancels a handshake or prompt.
    @discardableResult
    public func autoConnect(hostID: UUID) -> Task<Void, Never>? {
        guard canAutoConnect(hostID: hostID) else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.connectAndList(hostID: hostID)
            self.autoConnectTasks[hostID] = nil
        }
        autoConnectTasks[hostID] = task
        return task
    }

    private func connectAndList(hostID: UUID) async {
        guard hosts.contains(where: { $0.id == hostID }) else { return }
        do {
            _ = try await provider(for: hostID)
            await refreshWorkspaces(hostID: hostID)
        } catch {
            fail(hostID: hostID, error)
        }
    }

    /// Relists the host's workspaces and republishes its rows.
    ///
    /// Refreshes overlap (create, close, topology notifications, the list
    /// reappearing), and a slow listing that started before a create must not
    /// replace the newer one: only the most recently started listing for the
    /// host publishes; the newer one publishes when it lands.
    public func refreshWorkspaces(hostID: UUID) async {
        guard let provider = providers[hostID] else { return }
        refreshGenerations[hostID, default: 0] &+= 1
        let generation = refreshGenerations[hostID]
        do {
            let workspaces = try await provider.listWorkspaces()
            guard refreshGenerations[hostID] == generation, providers[hostID] === provider else { return }
            workspacesByHost[hostID] = workspaces
            // A listing through the live provider proves the host works.
            // Clears an earlier failure (tmux was missing, a listing failed)
            // that `connection(for:)` never revisits while its connection is
            // cached, so the title, rows, and empty state stop reading failed.
            statusByHost[hostID] = .connected
            if let host = hosts.first(where: { $0.id == hostID }) { publish(host: host) }
        } catch {
            guard refreshGenerations[hostID] == generation else { return }
            fail(hostID: hostID, error)
        }
    }

    /// The workspace list is showing this host again (Back from a
    /// workspace, return to the foreground): relist it when connected so
    /// sessions created or closed elsewhere appear without pull-to-refresh.
    /// A host that is not connected is left to ``autoConnect(hostID:)``.
    public func refreshIfConnected(hostID: UUID) {
        guard providers[hostID] != nil else { return }
        Task { await refreshWorkspaces(hostID: hostID) }
    }

    /// Test seam: a provider standing in for a connected host's tmux (the
    /// host has plain shells and no cmux-tui).
    func installProviderForTesting(_ provider: any MobileSSHWorkspaceProvider, hostID: UUID) {
        installProvidersForTesting(tmux: provider, plain: nil, hostID: hostID)
    }

    /// Test seam: stand-ins for a connected host's tmux and shells.
    func installProvidersForTesting(
        tmux: any MobileSSHWorkspaceProvider,
        plain: (any MobileSSHWorkspaceProvider)?,
        hostID: UUID
    ) {
        let registry = MobileSSHHostProviders.testing(tmux: tmux, plain: plain)
        providers[hostID] = registry
        kindAvailabilityByHost[hostID] = registry.availability
    }

    /// The host's last published workspaces (kind-encoded local ids).
    func workspacesByHostSnapshot(_ hostID: UUID) -> [MobileSSHWorkspace]? {
        workspacesByHost[hostID]
    }

    /// Test seam: records a failure the way a failed connect or listing does.
    func failForTesting(hostID: UUID, _ error: any Error) {
        fail(hostID: hostID, error)
    }

    /// ``refreshIfConnected(hostID:)`` for every connected host.
    public func refreshConnectedHosts() {
        for hostID in providers.keys { refreshIfConnected(hostID: hostID) }
    }

    /// The workspace kinds `+` offers for a host; every kind until the host
    /// has been probed.
    public func kindAvailability(hostID: UUID) -> [MobileSSHKindAvailability] {
        kindAvailabilityByHost[hostID] ?? MobileSSHKindAvailability.unprobed
    }

    /// The kind of an SSH workspace or surface id, parsed from the id.
    public nonisolated func kind(ofScopedID scopedID: String) -> MobileSSHWorkspaceKind? {
        MobileSSHLocalID(scopedID: scopedID)?.kind
    }

    /// Creates a workspace of `kind` (a cmux-tui workspace, a tmux session,
    /// or a shell) and returns its scoped row id.
    @discardableResult
    public func createWorkspace(hostID: UUID, kind: MobileSSHWorkspaceKind) async -> String? {
        do {
            let provider = try await provider(for: hostID)
            let workspace = try await provider.createWorkspace(kind: kind) { [weak self] installing in
                if installing {
                    self?.installingCmuxTUIHosts.insert(hostID)
                } else {
                    self?.installingCmuxTUIHosts.remove(hostID)
                }
            }
            kindAvailabilityByHost[hostID] = provider.availability
            await refreshWorkspaces(hostID: hostID)
            if !(workspacesByHost[hostID] ?? []).contains(where: { $0.id == workspace.id }) {
                workspacesByHost[hostID, default: []].append(workspace)
                if let host = hosts.first(where: { $0.id == hostID }) { publish(host: host) }
            }
            return MobileSSHIdentifier(host: hostID, local: workspace.id).rawValue
        } catch {
            fail(hostID: hostID, error)
            return nil
        }
    }

    public func closeWorkspace(scopedID: String) async {
        guard let hostID = MobileSSHIdentifier(scopedID).hostID,
              let local = MobileSSHLocalID(scopedID: scopedID),
              let registry = providers[hostID] else { return }
        for terminal in workspacesByHost[hostID]?.first(where: { $0.id == local.rawValue })?.terminals ?? [] {
            await detach(surfaceID: MobileSSHIdentifier(host: hostID, local: terminal.id).rawValue)
        }
        if let provider = try? await registry.provider(for: local) {
            try? await provider.closeWorkspace(id: local.providerID)
        }
        await refreshWorkspaces(hostID: hostID)
    }

    /// Closes the host's connection at the user's request. It stays
    /// disconnected (no automatic reconnect) until opened again.
    public func disconnect(hostID: UUID) async {
        autoConnectSuppressed.insert(hostID)
        await closeConnection(hostID: hostID)
    }

    /// Tears down the host's connection, attachments, and forwards, and
    /// returns it to idle. Leaves automatic-connect eligibility to callers.
    private func closeConnection(hostID: UUID) async {
        autoConnectTasks.removeValue(forKey: hostID)?.cancel()
        for surfaceID in attachments.keys where MobileSSHIdentifier(surfaceID).hostID == hostID {
            await detach(surfaceID: surfaceID)
        }
        for panelID in browserSessions.keys where MobileSSHIdentifier(panelID).hostID == hostID {
            await stopBrowser(panelID: panelID)
        }
        providers[hostID] = nil
        connectTasks[hostID]?.cancel()
        connectTasks[hostID] = nil
        stopAllPortForwards(hostID: hostID)
        if let connection = connections.removeValue(forKey: hostID) { await connection.close() }
        statusByHost[hostID] = .idle
    }

    // MARK: Files and forwarding

    /// Active local port forwards per host, newest last.
    public private(set) var forwardsByHost: [UUID: [SSHLocalPortForward]] = [:]

    /// Opens an SFTP session on the host's connection (connecting if needed).
    public func openSFTP(hostID: UUID) async throws -> SFTPClient {
        try await SFTPClient.open(on: try await connection(for: hostID))
    }

    /// Forwards `http://127.0.0.1:<localPort>` on the phone to
    /// `remoteHost:remotePort` as seen from the server (PRD D7).
    public func startPortForward(hostID: UUID, remotePort: Int, remoteHost: String = "127.0.0.1") async throws -> SSHLocalPortForward {
        let forward = try await SSHLocalPortForward.start(
            over: try await connection(for: hostID),
            targetHost: remoteHost,
            targetPort: remotePort
        )
        forwardsByHost[hostID, default: []].append(forward)
        return forward
    }

    /// Whether `connection` is still the host's current connection.
    func isCurrentConnection(_ connection: SSHConnection, hostID: UUID) -> Bool {
        connections[hostID] === connection
    }

    /// The host's live connection, connecting if needed (for extensions).
    func liveConnection(hostID: UUID) async throws -> SSHConnection {
        try await connection(for: hostID)
    }

    /// The SOCKS proxy per host for the native browser (see
    /// `MobileSSHComputers+Browser.swift`).
    @ObservationIgnored var browserProxies: [UUID: SSHSocksProxy] = [:]
    @ObservationIgnored var pendingBrowserProxies: [UUID: Task<SSHSocksProxy, any Error>] = [:]
    /// The proxy port a host used last, rebound after a reconnect so the
    /// browser's data store keeps pointing at it.
    @ObservationIgnored var lastBrowserProxyPorts: [UUID: Int] = [:]
    /// Same-port loopback forwards on the phone, by port (one host each).
    @ObservationIgnored var loopbackForwards: [Int: (hostID: UUID, forward: SSHLocalPortForward)] = [:]
    /// Phone ports that could not be bound for a host's loopback mirror
    /// (busy), not retried until its connection changes.
    @ObservationIgnored var loopbackBusyPorts: [UUID: Set<Int>] = [:]
    /// Closing listeners of a host's previous connection; a restart awaits
    /// them so it can rebind the same ports.
    @ObservationIgnored var browserNetworkTeardowns: [UUID: Task<Void, Never>] = [:]
    /// Hosts whose native browser was used, so a reconnect restores the proxy.
    @ObservationIgnored var browserHosts: Set<UUID> = []

    /// Forwards ride the host's connection, so they end with it (PRD D7).
    private func stopAllPortForwards(hostID: UUID) {
        stopBrowserNetwork(hostID: hostID)
        guard let forwards = forwardsByHost.removeValue(forKey: hostID) else { return }
        Task { for forward in forwards { await forward.stop() } }
    }

    public func stopPortForward(hostID: UUID, localPort: Int) async {
        guard let forward = forwardsByHost[hostID]?.first(where: { $0.localPort == localPort }) else { return }
        forwardsByHost[hostID]?.removeAll { $0.localPort == localPort }
        await forward.stop()
    }

    /// The current directory of an SSH terminal's shell, for the Files chip:
    /// asks the host's provider (cmux-tui `process-info`, tmux
    /// `#{pane_current_path}`). `nil` when the provider cannot tell (plain
    /// shells) or the host is not connected; the file browser then starts in
    /// the remote home folder, where a plain shell starts.
    public func currentDirectory(surfaceID: String) async -> String? {
        guard let hostID = MobileSSHIdentifier(surfaceID).hostID,
              let local = MobileSSHLocalID(scopedID: surfaceID),
              let provider = try? await providers[hostID]?.provider(for: local) else { return nil }
        return await provider.reportedCurrentDirectory(terminalID: local.providerID)
    }

    /// Runs a one-off command on the host (used by upload flows to learn `$HOME`).
    public func exec(hostID: UUID, _ command: String) async throws -> SSHExecResult {
        try await connection(for: hostID).exec(command)
    }

    /// The host behind an SSH computer, workspace row, or surface id.
    public nonisolated func hostID(forIdentifier identifier: String) -> UUID? {
        MobileSSHIdentifier(identifier).hostID
    }

    public func host(id: UUID) -> SSHHostRecord? {
        hosts.first { $0.id == id }
    }

    // MARK: Surfaces (called by the shell store)

    /// Records the phone's grid and resizes a live attachment (a cmux-tui
    /// terminal that released its geometry claims it again).
    func viewportChanged(surfaceID: String, columns: Int, rows: Int) {
        gridBySurface[surfaceID] = (columns, rows)
        if let attachment = attachments[surfaceID] {
            enqueueSizing(surfaceID) { await attachment.resize(columns: columns, rows: rows) }
        }
    }

    /// The surface left the screen (its view released its viewport). The
    /// stream stays attached for a warm return; a cmux-tui terminal gives
    /// up geometry so a laptop on the same session can resize it again
    /// (PRD D33).
    func viewportReleased(surfaceID: String) {
        guard let attachment = attachments[surfaceID] else { return }
        enqueueSizing(surfaceID) { await attachment.releaseGeometry() }
    }

    /// Runs a surface's resizes and geometry releases in call order: a
    /// quick leave-and-return must end claimed, never released.
    private func enqueueSizing(_ surfaceID: String, _ operation: @escaping @MainActor () async -> Void) {
        let previous = sizingTasks[surfaceID]
        sizingTasks[surfaceID] = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Repaints a (re)mounted surface: attaches on first use, otherwise
    /// replays retained output.
    func replay(surfaceID: String) {
        if attachments[surfaceID] != nil || attachTasks[surfaceID] != nil {
            sink?.sshDeliver(Self.replacement(replaying: replayBySurface[surfaceID] ?? Data()), surfaceID: surfaceID)
            return
        }
        attach(surfaceID: surfaceID)
    }

    /// Bytes that replace a surface's whole terminal with `history`.
    ///
    /// A full reset (RIS) first, so the replacement never inherits local
    /// state from earlier bytes (alternate screen, scroll region, origin
    /// mode, pending synchronized update); then clear screen and scrollback.
    /// `history` is output the program produced earlier, so its terminal
    /// query requests are stripped: the program is no longer waiting for
    /// answers, and a phone that answers for the PTY (plain/tmux) would type
    /// them into whatever runs now. Only live output may produce replies.
    static func replacement(replaying history: Data) -> Data {
        var bytes = Data("\u{1B}c\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8)
        bytes.append(TerminalReplayQueryFilter.removingQueryRequests(history))
        return bytes
    }

    /// The grid a surface must render at when the server fixes it (a tmux
    /// pane in a split window); `nil` when the phone's grid is the PTY's.
    func remoteGrid(surfaceID: String) -> (columns: Int, rows: Int)? {
        remoteGridBySurface[surfaceID]
    }

    func input(_ data: Data, surfaceID: String) {
        guard let attachment = attachments[surfaceID] else {
            // Keystrokes typed while the attach is in flight are sent once
            // it lands, in order.
            if attachTasks[surfaceID] != nil {
                pendingInputBySurface[surfaceID, default: Data()].append(data)
                return
            }
            // Typing into an ended session reattaches (plain opens a new shell).
            attach(surfaceID: surfaceID)
            return
        }
        Task { await attachment.write(data) }
    }

    private func attach(surfaceID: String) {
        guard let hostID = MobileSSHIdentifier(surfaceID).hostID,
              let local = MobileSSHLocalID(scopedID: surfaceID),
              attachTasks[surfaceID] == nil else { return }
        let grid = gridBySurface[surfaceID] ?? (80, 24)
        attachTasks[surfaceID] = Task { [weak self] in
            guard let self else { return }
            defer { self.attachTasks[surfaceID] = nil }
            do {
                let provider = try await self.provider(for: hostID).provider(for: local)
                replayBySurface[surfaceID] = Data()
                sink?.sshDeliver(Self.replacement(replaying: Data()), surfaceID: surfaceID)
                let attachment = try await provider.attach(
                    terminalID: local.providerID,
                    columns: grid.columns,
                    rows: grid.rows
                ) { [weak self] event in
                    self?.handle(event, surfaceID: surfaceID)
                }
                attachments[surfaceID] = attachment
                if let pending = pendingInputBySurface.removeValue(forKey: surfaceID) {
                    await attachment.write(pending)
                }
                if let latest = gridBySurface[surfaceID], latest != grid {
                    await attachment.resize(columns: latest.columns, rows: latest.rows)
                }
            } catch {
                pendingInputBySurface[surfaceID] = nil
                fail(hostID: hostID, error)
                let message = "\r\n\u{1B}[31m" + Self.describe(error) + "\u{1B}[0m\r\n"
                sink?.sshDeliver(Data(message.utf8), surfaceID: surfaceID)
            }
        }
    }

    private func detach(surfaceID: String) async {
        attachTasks.removeValue(forKey: surfaceID)?.cancel()
        sizingTasks[surfaceID] = nil
        if let attachment = attachments.removeValue(forKey: surfaceID) {
            await attachment.detach()
        }
    }

    private func handle(_ event: MobileSSHAttachEvent, surfaceID: String) {
        switch event {
        case .snapshot(let bytes):
            // A server snapshot (cmux-tui vt-state) is history too.
            replayBySurface[surfaceID] = bytes
            sink?.sshDeliver(Self.replacement(replaying: bytes), surfaceID: surfaceID)
        case .output(let bytes):
            var retained = replayBySurface[surfaceID] ?? Data()
            retained.append(bytes)
            if retained.count > Self.replayCap {
                retained = Data(retained.suffix(Self.replayCap))
            }
            replayBySurface[surfaceID] = retained
            sink?.sshDeliver(bytes, surfaceID: surfaceID)
        case .remoteGrid(let columns, let rows):
            remoteGridBySurface[surfaceID] = (columns, rows)
            sink?.sshApplyViewport(surfaceID: surfaceID)
        case .ended:
            attachments[surfaceID] = nil
            let notice = L10nSSH().sessionEnded
            sink?.sshDeliver(Data("\r\n\u{1B}[2m[\(notice)]\u{1B}[0m\r\n".utf8), surfaceID: surfaceID)
            if let hostID = MobileSSHIdentifier(surfaceID).hostID {
                Task { await self.refreshWorkspaces(hostID: hostID) }
            }
        }
    }

    // MARK: Internals

    /// The host's registry of workspace kinds, probing the host on first
    /// use of a connection. No questions: every kind is served at once.
    func provider(for hostID: UUID) async throws -> MobileSSHHostProviders {
        if let provider = providers[hostID] { return provider }
        let connection = try await connection(for: hostID)
        guard let host = hosts.first(where: { $0.id == hostID }) else { throw SSHConnectionError.closed }
        let registry = await MobileSSHHostProviders.make(connection: connection, host: host)
        // A concurrent caller may have finished first on the same connection.
        if let existing = providers[hostID] { return existing }
        guard connections[hostID] === connection else { throw SSHConnectionError.closed }
        registry.onTopologyChange = { [weak self] in
            Task { await self?.refreshWorkspaces(hostID: hostID) }
        }
        providers[hostID] = registry
        kindAvailabilityByHost[hostID] = registry.availability
        return registry
    }

    private func connection(for hostID: UUID) async throws -> SSHConnection {
        if let connection = connections[hostID] { return connection }
        if let task = connectTasks[hostID] { return try await task.value }
        guard let host = hosts.first(where: { $0.id == hostID }) else { throw SSHConnectionError.closed }
        statusByHost[hostID] = .connecting
        publish(host: host)
        let task = Task { () throws -> SSHConnection in
            guard let keyID = host.keyID else { throw MobileSSHRuntimeError.noKey }
            let key = try await keyStore.privateKey(for: keyID)
            let jump = try await jumpConnection(for: host)
            return try await SSHConnection.connect(
                to: host.endpoint,
                credentials: [.privateKey(key)],
                hostKeyVerifier: verifier(for: host),
                via: jump
            )
        }
        connectTasks[hostID] = task
        defer { connectTasks[hostID] = nil }
        let connection: SSHConnection
        do {
            connection = try await task.value
        } catch {
            // Record the failure on THIS host too: when it is a jump host,
            // the caller only reports the host it was asked to open, and
            // this one would otherwise stay "connecting" forever.
            fail(hostID: hostID, error)
            throw error
        }
        connections[hostID] = connection
        statusByHost[hostID] = .connected
        publish(host: host)
        connection.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in self?.connectionClosed(hostID: hostID, connection: connection) }
        }
        restoreBrowserProxy(hostID: hostID)
        return connection
    }

    private func jumpConnection(for host: SSHHostRecord) async throws -> SSHConnection? {
        guard let jumpID = host.jumpHostID, jumpID != host.id else { return nil }
        return try await connection(for: jumpID)
    }

    private func connectionClosed(hostID: UUID, connection: SSHConnection) {
        guard connections[hostID] === connection else { return }
        connections[hostID] = nil
        providers[hostID] = nil
        attachments = attachments.filter { MobileSSHIdentifier($0.key).hostID != hostID }
        // Browser pumps see the transport close and report `.ended` themselves.
        stopAllPortForwards(hostID: hostID)
        statusByHost[hostID] = .idle
        if let host = hosts.first(where: { $0.id == hostID }) { publish(host: host) }
    }

    /// Whether automatic connects are paused for the host (persisted).
    public func isAutoConnectPaused(hostID: UUID) -> Bool {
        host(id: hostID)?.isAutoConnectPaused ?? false
    }

    /// Updates the persisted pause flag. The in-memory record changes at
    /// once so ``canAutoConnect(hostID:)`` sees it before the write lands.
    /// Writes run one after another, so a pause followed by a resume can
    /// never land on disk in the opposite order.
    private func setAutoConnectPaused(_ paused: Bool, hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }),
              hosts[index].isAutoConnectPaused != paused else { return }
        hosts[index].autoConnectPaused = paused ? true : nil
        let generation = autoConnectPauseGeneration[hostID, default: 0] + 1
        autoConnectPauseGeneration[hostID] = generation
        let store = hostStore
        let previous = autoConnectPauseWrite
        autoConnectPauseWrite = Task {
            await previous?.value
            guard var stored = await store.host(id: hostID) else { return }
            stored.autoConnectPaused = paused ? true : nil
            try? await store.upsert(stored)
            // A newer change for this host is queued behind this write; it
            // owns the in-memory flag, and restoring this older value would
            // undo it until that write lands.
            guard autoConnectPauseGeneration[hostID] == generation else { return }
            // A reload that ran before this write landed read the old flag.
            if let index = hosts.firstIndex(where: { $0.id == hostID }) {
                hosts[index].autoConnectPaused = stored.autoConnectPaused
            }
        }
    }

    /// Returns once every pause-flag write queued so far has reached disk.
    func autoConnectPauseWritesSettled() async {
        await autoConnectPauseWrite?.value
    }

    func verifier(for host: SSHHostRecord) -> MobileSSHHostKeyVerifier {
        MobileSSHHostKeyVerifier(host: host, store: hostStore) { [weak self] prompt in
            await self?.ask(prompt) ?? .cancel
        }
    }

    private func fail(hostID: UUID, _ error: any Error) {
        if error is CancellationError {
            // A declined question: stay manual rather than asking again.
            autoConnectSuppressed.insert(hostID)
            statusByHost[hostID] = connections[hostID] == nil ? .idle : .connected
        } else {
            statusByHost[hostID] = .failed(Self.describe(error))
        }
        if let host = hosts.first(where: { $0.id == hostID }) { publish(host: host) }
    }

    static func describe(_ error: any Error) -> String {
        if let faceID = MobileSSHBiometryErrorCopy().message(for: error) { return faceID }
        return switch error {
        case SSHConnectionError.authenticationFailed: L10nSSH().authFailed
        case SSHConnectionError.hostKeyRejected: L10nSSH().hostKeyRejected
        case MobileSSHRuntimeError.noKey: L10nSSH().noKey
        case MobileSSHRuntimeError.tmuxMissing: L10nSSH().tmuxMissing
        case MobileSSHRuntimeError.cmuxTUIMissing: L10nSSH().cmuxTUIMissing
        case MobileSSHRuntimeError.cmuxTUISessionGone: L10nSSH().cmuxTUISessionGone
        case MobileSSHCmuxTUIInstaller.InstallError.unsupportedPlatform(let os, let arch): L10nSSH().cmuxTUIUnsupported(os: os, arch: arch)
        case let network as NWError: describe(network)
        case let posix as POSIXError: describe(posix.code)
        default: String(describing: error)
        }
    }

    /// Plain wording for the network failures a connect can hit, instead of
    /// raw codes like `POSIXErrorCode(rawValue: 61)`.
    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): describe(code)
        case .dns: L10nSSH().hostNotFound
        default: L10nSSH().unreachable
        }
    }

    private static func describe(_ code: POSIXErrorCode) -> String {
        switch code {
        case .ECONNREFUSED: L10nSSH().connectionRefused
        case .ETIMEDOUT: L10nSSH().connectTimedOut
        default: L10nSSH().unreachable
        }
    }

    private func publish(host: SSHHostRecord) {
        let computerID = MobileSSHIdentifier(computerOf: host.id).rawValue
        let rows = (workspacesByHost[host.id] ?? []).map { workspace in
            MobileWorkspacePreview(
                id: MobileWorkspacePreview.ID(rawValue: MobileSSHIdentifier(host: host.id, local: workspace.id).rawValue),
                macDeviceID: computerID,
                macDisplayName: host.name,
                name: workspace.name,
                // Where a Mac row shows its latest activity, an SSH row
                // names its kind (PRD D31).
                previewText: L10nSSH().kindLabel(workspace.kind, cmuxTUISession: workspace.cmuxTUISession),
                terminals: workspace.terminals.map {
                    MobileTerminalPreview(
                        id: MobileTerminalPreview.ID(rawValue: MobileSSHIdentifier(host: host.id, local: $0.id).rawValue),
                        name: $0.name
                    )
                },
                surfaces: workspace.browsers.map {
                    MobileSurfacePreview(
                        id: MobileSurfacePreview.ID(rawValue: MobileSSHIdentifier(host: host.id, local: $0.id).rawValue),
                        kind: .browser,
                        title: Self.browserTitle($0)
                    )
                }
            )
        }
        let status: MobileMacConnectionStatus = switch statusByHost[host.id] ?? .idle {
        case .connected: .connected
        case .connecting: .reconnecting
        case .failed: .unavailable
        case .idle: rows.isEmpty ? .unavailable : .connected
        }
        publishBrowserPanels(host: host)
        sink?.sshPublishWorkspaceState(
            MacWorkspaceState(
                macDeviceID: computerID,
                instanceTag: nil,
                displayName: host.name,
                workspaces: rows,
                groups: [],
                workspaceGroupsAreAuthoritative: true,
                status: status,
                workspaceSnapshotIsAuthoritative: true,
                actionCapabilities: MobileWorkspaceActionCapabilities(supportsCloseActions: true)
            )
        )
    }
}

// MARK: - Browser surfaces (D23)

extension MobileSSHComputers {
    static func browserTitle(_ browser: MobileSSHBrowser) -> String {
        if !browser.title.isEmpty { return browser.title }
        if let url = browser.url, !url.isEmpty { return url }
        return L10nSSH().browserUntitled
    }

    /// Streamable browser panels of an SSH workspace row.
    func browserPanels(inWorkspace workspaceID: String) -> [MobileBrowserPanelDescriptor] {
        guard let hostID = MobileSSHIdentifier(workspaceID).hostID,
              let local = MobileSSHIdentifier(workspaceID).localID,
              let workspace = workspacesByHost[hostID]?.first(where: { $0.id == local }) else { return [] }
        return workspace.browsers.map { descriptor(for: $0, hostID: hostID, workspaceID: workspaceID) }
    }

    private func descriptor(for browser: MobileSSHBrowser, hostID: UUID, workspaceID: String) -> MobileBrowserPanelDescriptor {
        let panelID = MobileSSHIdentifier(host: hostID, local: browser.id).rawValue
        let metadata = browserMetadata[panelID]
        // Before the first frame, estimate the page from the server grid at
        // a typical terminal cell (9x16); the first frame replaces it.
        let size = browserPageSize[panelID]
            ?? (Double((browser.columns ?? 80) * 9), Double((browser.rows ?? 24) * 16))
        return MobileBrowserPanelDescriptor(
            panelID: panelID,
            workspaceID: workspaceID,
            url: metadata?.url ?? browser.url,
            title: metadata?.title ?? Self.browserTitle(browser),
            pageWidth: size.width,
            pageHeight: size.height,
            canGoBack: true,
            canGoForward: true,
            isLoading: metadata?.isLoading ?? false
        )
    }

    private func publishBrowserPanels(host: SSHHostRecord) {
        for workspace in workspacesByHost[host.id] ?? [] {
            let workspaceID = MobileSSHIdentifier(host: host.id, local: workspace.id).rawValue
            let panels = browserPanels(inWorkspace: workspaceID)
            // Metadata-only churn must not bump the store's discovery revision.
            let identity = panels.map(\.panelID)
            guard publishedBrowserPanels[workspaceID]?.map(\.panelID) != identity else { continue }
            publishedBrowserPanels[workspaceID] = panels
            sink?.sshReplaceBrowserPanels(workspaceID: workspaceID, with: panels)
        }
    }

    func isBrowserStreaming(panelID: String) -> Bool {
        browserSessions[panelID] != nil
    }

    func browserSession(panelID: String) -> (any MobileSSHAttachedBrowser)? {
        browserSessions[panelID]
    }

    /// Attaches a browser tab (idempotent) and returns its descriptor.
    func startBrowser(panelID: String, viewport: MobileBrowserViewport?) async throws -> MobileBrowserPanelDescriptor {
        guard let hostID = MobileSSHIdentifier(panelID).hostID,
              let local = MobileSSHIdentifier(panelID).localID,
              let parsed = MobileSSHLocalID(rawValue: local) else { throw MobileSSHRuntimeError.browserUnavailable }
        guard let (workspaceID, browser) = locateBrowser(hostID: hostID, local: local) else {
            throw MobileSSHRuntimeError.browserUnavailable
        }
        if browserSessions[panelID] == nil {
            guard let provider = try await provider(for: hostID).provider(for: parsed) as? any MobileSSHBrowserProviding else {
                throw MobileSSHRuntimeError.browserUnavailable
            }
            let session = try await provider.attachBrowser(
                browserID: parsed.providerID,
                viewport: viewport.map { ($0.width, $0.height) }
            ) { [weak self] event in
                self?.handleBrowser(event, panelID: panelID)
            }
            if browserSessions[panelID] != nil {
                // Lost a race with another start; keep the first stream.
                await session.detach()
            } else {
                browserSessions[panelID] = session
                browserPanelsWithFrames.remove(panelID)
            }
        }
        return descriptor(for: browser, hostID: hostID, workspaceID: workspaceID)
    }

    /// Detaches a browser stream. The tab keeps running on the server.
    func stopBrowser(panelID: String) async {
        guard let session = browserSessions.removeValue(forKey: panelID) else { return }
        await session.detach()
    }

    private func locateBrowser(hostID: UUID, local: String) -> (workspaceID: String, browser: MobileSSHBrowser)? {
        for workspace in workspacesByHost[hostID] ?? [] {
            if let browser = workspace.browsers.first(where: { $0.id == local }) {
                return (MobileSSHIdentifier(host: hostID, local: workspace.id).rawValue, browser)
            }
        }
        return nil
    }

    private func handleBrowser(_ event: MobileSSHBrowserEvent, panelID: String) {
        switch event {
        case let .state(url, title, isLoading, failure):
            let state = MobileBrowserStateEvent(
                panelID: panelID,
                url: url,
                title: failure.map { $0.isEmpty ? L10nSSH().browserFailed : L10nSSH().browserFailed + ": " + $0 } ?? title,
                // cmux-tui does not report history availability; keep both
                // buttons enabled (the server no-ops at either end).
                canGoBack: true,
                canGoForward: true,
                isLoading: isLoading,
                progress: isLoading ? 0.3 : 1,
                editableFocused: false
            )
            browserMetadata[panelID] = state
            sink?.sshDeliverBrowserState(state)
        case let .frame(sequence, pageWidth, pageHeight, pixelWidth, pixelHeight, base64PNG):
            browserPageSize[panelID] = (pageWidth, pageHeight)
            browserPanelsWithFrames.insert(panelID)
            sink?.sshDeliverBrowserFrame(MobileBrowserFrameEvent(
                panelID: panelID,
                sequence: sequence,
                format: .png,
                pageWidth: pageWidth,
                pageHeight: pageHeight,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                dataBase64: base64PNG
            ))
        case .ended:
            guard browserSessions.removeValue(forKey: panelID) != nil else { return }
            let retry = browserPanelsWithFrames.remove(panelID) != nil
            sink?.sshBrowserStreamEnded(panelID: panelID, retry: retry)
        }
    }
}

/// The user's answer to a ``MobileSSHPrompt``.
public enum MobileSSHPromptAnswer: Sendable, Equatable {
    case trust
    case cancel
}

enum MobileSSHRuntimeError: Error {
    case noKey
    case tmuxMissing
    /// A cmux-tui operation on a host without an installed cmux-tui.
    case cmuxTUIMissing
    /// A discovered cmux-tui session's owner stopped.
    case cmuxTUISessionGone
    /// The browser tab is gone or the host's mode cannot stream browsers.
    case browserUnavailable
}

/// Pins host keys on first use (after asking) and stops on a changed key.
struct MobileSSHHostKeyVerifier: SSHHostKeyVerifier {
    let host: SSHHostRecord
    let store: SSHHostStore
    let ask: @Sendable (MobileSSHPrompt) async -> MobileSSHPromptAnswer

    func verify(_ key: SSHHostKey, for endpoint: SSHEndpoint) async -> Bool {
        let identity = endpoint.hostKeyIdentity
        switch SSHHostKeyVerdict(presented: key, pinned: await store.pinnedKey(for: identity)) {
        case .trusted:
            return true
        case .unknown:
            guard await ask(.trustNewHostKey(host: host, key: key)) == .trust else { return false }
        case .changed(let pinned, let presented):
            guard await ask(.hostKeyChanged(host: host, pinned: pinned, presented: presented)) == .trust else { return false }
        }
        await store.pin(key, for: identity)
        return true
    }
}

/// Plain-language copy for a Secure Enclave key that needs Face ID and
/// could not get it (CryptoKit reports this as "Authentication failure.").
public struct MobileSSHBiometryErrorCopy {
    /// Creates the copy provider.
    public init() {}

    /// A friendly message when `error` is a Face ID / key-authentication
    /// failure; `nil` for any other error.
    public func message(for error: any Error) -> String? {
        if let laError = error as? LAError {
            return message(for: laError.code)
        }
        let nsError = error as NSError
        if nsError.domain == LAErrorDomain, let code = LAError.Code(rawValue: nsError.code) {
            return message(for: code)
        }
        if case CryptoKitError.authenticationFailure = error {
            return biometryIsSetUp ? couldNotUse : notSetUp
        }
        return nil
    }

    private func message(for code: LAError.Code) -> String {
        switch code {
        case .biometryNotEnrolled, .biometryNotAvailable, .passcodeNotSet:
            notSetUp
        case .biometryLockout:
            L10n.string(
                "mobile.ssh.faceID.lockedOut",
                defaultValue: "Face ID is locked after too many attempts. Unlock your iPhone with its passcode, then try again."
            )
        default:
            couldNotUse
        }
    }

    private var biometryIsSetUp: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var notSetUp: String {
        L10n.string(
            "mobile.ssh.faceID.notSetUp",
            defaultValue: "Face ID isn't set up on this device. Set it up in Settings, or turn off Require Face ID for this key."
        )
    }

    var couldNotUse: String {
        L10n.string(
            "mobile.ssh.faceID.failed",
            defaultValue: "Couldn't use Face ID. Try again."
        )
    }
}
