import CMUXMobileCore
internal import CmuxMobileTerminalKit
internal import CryptoKit
internal import LocalAuthentication
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
    /// First connect: how should sessions persist? (PRD D9)
    case choosePersistence(host: SSHHostRecord, tmuxAvailable: Bool)

    /// The host an identity question (new or changed server key) is about;
    /// `nil` for other questions.
    public var identityHostID: UUID? {
        switch self {
        case .trustNewHostKey(let host, _), .hostKeyChanged(let host, _, _): host.id
        case .choosePersistence: nil
        }
    }

    public var id: String {
        switch self {
        case .trustNewHostKey(let host, _): "trust-\(host.id)"
        case .hostKeyChanged(let host, _, _): "changed-\(host.id)"
        case .choosePersistence(let host, _): "persist-\(host.id)"
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
/// saved hosts and keys, live connections, the per-host persistence
/// provider, and the terminal attachments behind each SSH surface.
///
/// SSH computers render through the shell's ordinary per-computer stores,
/// like the demonstration computer: each host publishes one
/// ``MacWorkspaceState`` keyed by ``MobileSSHIdentifiers/computerID(host:)``,
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

    @ObservationIgnored weak var sink: (any MobileSSHComputersSink)?
    @ObservationIgnored private var connections: [UUID: SSHConnection] = [:]
    @ObservationIgnored private var connectTasks: [UUID: Task<SSHConnection, any Error>] = [:]
    @ObservationIgnored private var providers: [UUID: any MobileSSHWorkspaceProvider] = [:]
    @ObservationIgnored private var workspacesByHost: [UUID: [MobileSSHWorkspace]] = [:]
    /// Bumped per listing started, so only the newest listing publishes.
    @ObservationIgnored private var refreshGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored private var attachments: [String: any MobileSSHAttachedTerminal] = [:]
    @ObservationIgnored private var attachTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var gridBySurface: [String: (columns: Int, rows: Int)] = [:]
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
    @ObservationIgnored private var promptContinuations: [String: CheckedContinuation<MobileSSHPromptAnswer, Never>] = [:]
    /// Hosts that stay manual until the user connects them again: the user
    /// disconnected them or declined a first-connect question.
    @ObservationIgnored private var autoConnectSuppressed: Set<UUID> = []
    @ObservationIgnored private var autoConnectTasks: [UUID: Task<Void, Never>] = [:]
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

    public func saveHost(_ host: SSHHostRecord) async throws {
        try await hostStore.upsert(host)
        await reload()
    }

    public func deleteHost(id: UUID) async throws {
        await disconnect(hostID: id)
        try await hostStore.delete(id: id)
        sink?.sshRemoveWorkspaceState(computerID: MobileSSHIdentifiers.computerID(host: id))
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
        _ = try await SSHKeyInstaller.install(
            publicKeyLine: record.publicKeyLine,
            endpoint: host.endpoint,
            password: password,
            verifyWith: .privateKey(key),
            hostKeyVerifier: verifier(for: host),
            via: jump
        )
    }

    // MARK: Prompts

    /// Resolves the oldest matching prompt.
    ///
    /// Declining an identity question (a new or a changed server key) pauses
    /// automatic connects for that host, persistently, so reopening the app
    /// or its list does not ask again. Only an explicit connect
    /// (``open(hostID:)``) resumes them.
    public func answer(_ prompt: MobileSSHPrompt, with answer: MobileSSHPromptAnswer) {
        prompts.removeAll { $0.id == prompt.id }
        if answer != .trust, let hostID = prompt.identityHostID {
            setAutoConnectPaused(true, hostID: hostID)
        }
        promptContinuations.removeValue(forKey: prompt.id)?.resume(returning: answer)
    }

    func ask(_ prompt: MobileSSHPrompt) async -> MobileSSHPromptAnswer {
        await withCheckedContinuation { continuation in
            promptContinuations[prompt.id]?.resume(returning: .cancel)
            promptContinuations[prompt.id] = continuation
            prompts.removeAll { $0.id == prompt.id }
            prompts.append(prompt)
        }
    }

    // MARK: Connections

    /// Connects (if needed), resolves the persistence mode, and refreshes
    /// the host's workspace rows. An explicit open re-enables automatic
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

    /// Test seam: a provider standing in for a connected host's.
    func installProviderForTesting(_ provider: any MobileSSHWorkspaceProvider, hostID: UUID) {
        providers[hostID] = provider
    }

    /// Test seam: records a failure the way a failed connect or listing does.
    func failForTesting(hostID: UUID, _ error: any Error) {
        fail(hostID: hostID, error)
    }

    /// ``refreshIfConnected(hostID:)`` for every connected host.
    public func refreshConnectedHosts() {
        for hostID in providers.keys { refreshIfConnected(hostID: hostID) }
    }

    /// Creates a workspace and returns its scoped row id.
    @discardableResult
    public func createWorkspace(hostID: UUID) async -> String? {
        do {
            let provider = try await provider(for: hostID)
            let workspace = try await provider.createWorkspace()
            await refreshWorkspaces(hostID: hostID)
            if !(workspacesByHost[hostID] ?? []).contains(where: { $0.id == workspace.id }) {
                workspacesByHost[hostID, default: []].append(workspace)
                if let host = hosts.first(where: { $0.id == hostID }) { publish(host: host) }
            }
            return MobileSSHIdentifiers.scopedID(host: hostID, local: workspace.id)
        } catch {
            fail(hostID: hostID, error)
            return nil
        }
    }

    public func closeWorkspace(scopedID: String) async {
        guard let hostID = MobileSSHIdentifiers.hostID(of: scopedID),
              let local = MobileSSHIdentifiers.localID(of: scopedID),
              let provider = providers[hostID] else { return }
        for terminal in workspacesByHost[hostID]?.first(where: { $0.id == local })?.terminals ?? [] {
            await detach(surfaceID: MobileSSHIdentifiers.scopedID(host: hostID, local: terminal.id))
        }
        try? await provider.closeWorkspace(id: local)
        await refreshWorkspaces(hostID: hostID)
    }

    /// Closes the host's connection at the user's request. It stays
    /// disconnected (no automatic reconnect) until opened again.
    public func disconnect(hostID: UUID) async {
        autoConnectSuppressed.insert(hostID)
        autoConnectTasks.removeValue(forKey: hostID)?.cancel()
        for surfaceID in attachments.keys where MobileSSHIdentifiers.hostID(of: surfaceID) == hostID {
            await detach(surfaceID: surfaceID)
        }
        for panelID in browserSessions.keys where MobileSSHIdentifiers.hostID(of: panelID) == hostID {
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
        guard let hostID = MobileSSHIdentifiers.hostID(of: surfaceID),
              let terminalID = MobileSSHIdentifiers.localID(of: surfaceID),
              let provider = providers[hostID] else { return nil }
        return await provider.reportedCurrentDirectory(terminalID: terminalID)
    }

    /// Runs a one-off command on the host (used by upload flows to learn `$HOME`).
    public func exec(hostID: UUID, _ command: String) async throws -> SSHExecResult {
        try await connection(for: hostID).exec(command)
    }

    /// The host behind an SSH computer, workspace row, or surface id.
    public nonisolated func hostID(forIdentifier identifier: String) -> UUID? {
        MobileSSHIdentifiers.hostID(of: identifier)
    }

    public func host(id: UUID) -> SSHHostRecord? {
        hosts.first { $0.id == id }
    }

    // MARK: Surfaces (called by the shell store)

    /// Records the phone's grid and resizes a live attachment.
    func viewportChanged(surfaceID: String, columns: Int, rows: Int) {
        gridBySurface[surfaceID] = (columns, rows)
        if let attachment = attachments[surfaceID] {
            Task { await attachment.resize(columns: columns, rows: rows) }
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
        guard let hostID = MobileSSHIdentifiers.hostID(of: surfaceID),
              let local = MobileSSHIdentifiers.localID(of: surfaceID),
              attachTasks[surfaceID] == nil else { return }
        let grid = gridBySurface[surfaceID] ?? (80, 24)
        attachTasks[surfaceID] = Task { [weak self] in
            guard let self else { return }
            defer { self.attachTasks[surfaceID] = nil }
            do {
                let provider = try await self.provider(for: hostID)
                replayBySurface[surfaceID] = Data()
                sink?.sshDeliver(Self.replacement(replaying: Data()), surfaceID: surfaceID)
                let attachment = try await provider.attach(
                    terminalID: local,
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
            let notice = L10nSSH.sessionEnded
            sink?.sshDeliver(Data("\r\n\u{1B}[2m[\(notice)]\u{1B}[0m\r\n".utf8), surfaceID: surfaceID)
            if let hostID = MobileSSHIdentifiers.hostID(of: surfaceID) {
                Task { await self.refreshWorkspaces(hostID: hostID) }
            }
        }
    }

    // MARK: Internals

    func provider(for hostID: UUID) async throws -> any MobileSSHWorkspaceProvider {
        if let provider = providers[hostID] { return provider }
        let connection = try await connection(for: hostID)
        guard var host = hosts.first(where: { $0.id == hostID }) else { throw SSHConnectionError.closed }
        let tmuxPath = await MobileSSHTmuxProvider.probe(on: connection)
        if host.persistence == nil || host.persistence?.isAvailable == false {
            switch await ask(.choosePersistence(host: host, tmuxAvailable: tmuxPath != nil)) {
            case .persistence(let mode):
                host.persistence = mode
                try await hostStore.upsert(host)
                hosts = await hostStore.all()
            default:
                throw CancellationError()
            }
        }
        let provider: any MobileSSHWorkspaceProvider
        switch host.persistence {
        case .tmux:
            guard let tmuxPath else { throw MobileSSHRuntimeError.tmuxMissing }
            provider = MobileSSHTmuxProvider(connection: connection, tmuxPath: tmuxPath)
        case .cmuxTUI:
            provider = try await MobileSSHCmuxTUIProvider.make(connection: connection, host: host)
        default:
            provider = MobileSSHPlainProvider(connection: connection)
        }
        (provider as? any MobileSSHTopologyReporting)?.onTopologyChange = { [weak self] in
            Task { await self?.refreshWorkspaces(hostID: hostID) }
        }
        providers[hostID] = provider
        return provider
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
        attachments = attachments.filter { MobileSSHIdentifiers.hostID(of: $0.key) != hostID }
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
    private func setAutoConnectPaused(_ paused: Bool, hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }),
              hosts[index].isAutoConnectPaused != paused else { return }
        hosts[index].autoConnectPaused = paused ? true : nil
        let store = hostStore
        Task {
            guard var stored = await store.host(id: hostID) else { return }
            stored.autoConnectPaused = paused ? true : nil
            try? await store.upsert(stored)
            // A reload that ran before this write landed read the old flag.
            if let index = hosts.firstIndex(where: { $0.id == hostID }) {
                hosts[index].autoConnectPaused = stored.autoConnectPaused
            }
        }
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
        if let faceID = MobileSSHBiometryErrorCopy.message(for: error) { return faceID }
        return switch error {
        case SSHConnectionError.authenticationFailed: L10nSSH.authFailed
        case SSHConnectionError.hostKeyRejected: L10nSSH.hostKeyRejected
        case MobileSSHRuntimeError.noKey: L10nSSH.noKey
        case MobileSSHRuntimeError.tmuxMissing: L10nSSH.tmuxMissing
        default: String(describing: error)
        }
    }

    private func publish(host: SSHHostRecord) {
        let computerID = MobileSSHIdentifiers.computerID(host: host.id)
        let rows = (workspacesByHost[host.id] ?? []).map { workspace in
            MobileWorkspacePreview(
                id: MobileWorkspacePreview.ID(rawValue: MobileSSHIdentifiers.scopedID(host: host.id, local: workspace.id)),
                macDeviceID: computerID,
                macDisplayName: host.name,
                name: workspace.name,
                terminals: workspace.terminals.map {
                    MobileTerminalPreview(
                        id: MobileTerminalPreview.ID(rawValue: MobileSSHIdentifiers.scopedID(host: host.id, local: $0.id)),
                        name: $0.name
                    )
                },
                surfaces: workspace.browsers.map {
                    MobileSurfacePreview(
                        id: MobileSurfacePreview.ID(rawValue: MobileSSHIdentifiers.scopedID(host: host.id, local: $0.id)),
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
        return L10nSSH.browserUntitled
    }

    /// Streamable browser panels of an SSH workspace row.
    func browserPanels(inWorkspace workspaceID: String) -> [MobileBrowserPanelDescriptor] {
        guard let hostID = MobileSSHIdentifiers.hostID(of: workspaceID),
              let local = MobileSSHIdentifiers.localID(of: workspaceID),
              let workspace = workspacesByHost[hostID]?.first(where: { $0.id == local }) else { return [] }
        return workspace.browsers.map { descriptor(for: $0, hostID: hostID, workspaceID: workspaceID) }
    }

    private func descriptor(for browser: MobileSSHBrowser, hostID: UUID, workspaceID: String) -> MobileBrowserPanelDescriptor {
        let panelID = MobileSSHIdentifiers.scopedID(host: hostID, local: browser.id)
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
            let workspaceID = MobileSSHIdentifiers.scopedID(host: host.id, local: workspace.id)
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
        guard let hostID = MobileSSHIdentifiers.hostID(of: panelID),
              let local = MobileSSHIdentifiers.localID(of: panelID) else { throw MobileSSHRuntimeError.browserUnavailable }
        guard let (workspaceID, browser) = locateBrowser(hostID: hostID, local: local) else {
            throw MobileSSHRuntimeError.browserUnavailable
        }
        if browserSessions[panelID] == nil {
            guard let provider = try await provider(for: hostID) as? any MobileSSHBrowserProviding else {
                throw MobileSSHRuntimeError.browserUnavailable
            }
            let session = try await provider.attachBrowser(
                browserID: local,
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
                return (MobileSSHIdentifiers.scopedID(host: hostID, local: workspace.id), browser)
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
                title: failure.map { $0.isEmpty ? L10nSSH.browserFailed : L10nSSH.browserFailed + ": " + $0 } ?? title,
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
    case persistence(SSHPersistenceMode)
    case cancel
}

enum MobileSSHRuntimeError: Error {
    case noKey
    case tmuxMissing
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
        switch SSHHostKeyPolicy.verdict(presented: key, pinned: await store.pinnedKey(for: identity)) {
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
public enum MobileSSHBiometryErrorCopy {
    /// A friendly message when `error` is a Face ID / key-authentication
    /// failure; `nil` for any other error.
    public static func message(for error: any Error) -> String? {
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

    private static func message(for code: LAError.Code) -> String {
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

    private static var biometryIsSetUp: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var notSetUp: String {
        L10n.string(
            "mobile.ssh.faceID.notSetUp",
            defaultValue: "Face ID isn't set up on this device. Set it up in Settings, or turn off Require Face ID for this key."
        )
    }

    static var couldNotUse: String {
        L10n.string(
            "mobile.ssh.faceID.failed",
            defaultValue: "Couldn't use Face ID. Try again."
        )
    }
}
