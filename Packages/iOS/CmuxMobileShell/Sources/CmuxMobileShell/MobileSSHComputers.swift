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
    @ObservationIgnored private var attachments: [String: any MobileSSHAttachedTerminal] = [:]
    @ObservationIgnored private var attachTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var gridBySurface: [String: (columns: Int, rows: Int)] = [:]
    /// Recent output per surface so a remounted view repaints without asking
    /// the server. Capped; cmux-tui re-sends a snapshot on reattach anyway.
    @ObservationIgnored private var replayBySurface: [String: Data] = [:]
    @ObservationIgnored private var promptContinuations: [String: CheckedContinuation<MobileSSHPromptAnswer, Never>] = [:]
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
    public func answer(_ prompt: MobileSSHPrompt, with answer: MobileSSHPromptAnswer) {
        prompts.removeAll { $0.id == prompt.id }
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
    /// the host's workspace rows.
    public func open(hostID: UUID) async {
        guard hosts.contains(where: { $0.id == hostID }) else { return }
        do {
            _ = try await provider(for: hostID)
            await refreshWorkspaces(hostID: hostID)
        } catch {
            fail(hostID: hostID, error)
        }
    }

    public func refreshWorkspaces(hostID: UUID) async {
        guard let provider = providers[hostID] else { return }
        do {
            workspacesByHost[hostID] = try await provider.listWorkspaces()
            if let host = hosts.first(where: { $0.id == hostID }) { publish(host: host) }
        } catch {
            fail(hostID: hostID, error)
        }
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

    public func disconnect(hostID: UUID) async {
        for surfaceID in attachments.keys where MobileSSHIdentifiers.hostID(of: surfaceID) == hostID {
            await detach(surfaceID: surfaceID)
        }
        providers[hostID] = nil
        connectTasks[hostID]?.cancel()
        connectTasks[hostID] = nil
        if let connection = connections.removeValue(forKey: hostID) { await connection.close() }
        statusByHost[hostID] = .idle
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
            var bytes = Data("\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8)
            bytes.append(replayBySurface[surfaceID] ?? Data())
            sink?.sshDeliver(bytes, surfaceID: surfaceID)
            return
        }
        attach(surfaceID: surfaceID)
    }

    func input(_ data: Data, surfaceID: String) {
        guard let attachment = attachments[surfaceID] else {
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
                sink?.sshDeliver(Data("\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8), surfaceID: surfaceID)
                let attachment = try await provider.attach(
                    terminalID: local,
                    columns: grid.columns,
                    rows: grid.rows
                ) { [weak self] event in
                    self?.handle(event, surfaceID: surfaceID)
                }
                attachments[surfaceID] = attachment
                if let latest = gridBySurface[surfaceID], latest != grid {
                    await attachment.resize(columns: latest.columns, rows: latest.rows)
                }
            } catch {
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
            replayBySurface[surfaceID] = bytes
            var reset = Data("\u{1B}c\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8)
            reset.append(bytes)
            sink?.sshDeliver(reset, surfaceID: surfaceID)
        case .output(let bytes):
            var retained = replayBySurface[surfaceID] ?? Data()
            retained.append(bytes)
            if retained.count > Self.replayCap {
                retained = Data(retained.suffix(Self.replayCap))
            }
            replayBySurface[surfaceID] = retained
            sink?.sshDeliver(bytes, surfaceID: surfaceID)
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

    private func provider(for hostID: UUID) async throws -> any MobileSSHWorkspaceProvider {
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
        let connection = try await task.value
        connections[hostID] = connection
        statusByHost[hostID] = .connected
        publish(host: host)
        connection.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in self?.connectionClosed(hostID: hostID, connection: connection) }
        }
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
        statusByHost[hostID] = .idle
        if let host = hosts.first(where: { $0.id == hostID }) { publish(host: host) }
    }

    func verifier(for host: SSHHostRecord) -> MobileSSHHostKeyVerifier {
        MobileSSHHostKeyVerifier(host: host, store: hostStore) { [weak self] prompt in
            await self?.ask(prompt) ?? .cancel
        }
    }

    private func fail(hostID: UUID, _ error: any Error) {
        if error is CancellationError {
            statusByHost[hostID] = connections[hostID] == nil ? .idle : .connected
        } else {
            statusByHost[hostID] = .failed(Self.describe(error))
        }
        if let host = hosts.first(where: { $0.id == hostID }) { publish(host: host) }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
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
                }
            )
        }
        let status: MobileMacConnectionStatus = switch statusByHost[host.id] ?? .idle {
        case .connected: .connected
        case .connecting: .reconnecting
        case .idle, .failed: rows.isEmpty ? .unavailable : .connected
        }
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

/// The user's answer to a ``MobileSSHPrompt``.
public enum MobileSSHPromptAnswer: Sendable, Equatable {
    case trust
    case persistence(SSHPersistenceMode)
    case cancel
}

enum MobileSSHRuntimeError: Error {
    case noKey
    case tmuxMissing
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
