import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation

/// Owns one immutable account/team pairing scope without running a terminal-viewer session.
@MainActor
public final class HivePairingController {
    /// Immutable paired-computer values for native directory and Settings adapters.
    public private(set) var computers: [HivePairedComputer] = []
    /// Called after authoritative local-store results change the visible pairing set.
    public var onChange: (@MainActor () -> Void)?

    private let store: any MobilePairedMacPairingStoring
    private let runtime: any MobileSyncRuntime
    private let userID: String
    private let teamID: String?
    private let email: String?
    private let ownDeviceID: String
    private let ownInstanceTag: String
    private let allowsLoopback: Bool
    private var client: MobileCoreRPCClient?
    private var disconnectTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, any Error>?
    private var isPairing = false
    private var isStopped = false
    private var loadGeneration: UInt64 = 0

    init(
        store: any MobilePairedMacPairingStoring, runtime: any MobileSyncRuntime,
        userID: String, teamID: String?, email: String?,
        ownDeviceID: String, ownInstanceTag: String, allowsLoopback: Bool
    ) {
        self.store = store
        self.runtime = runtime
        self.userID = userID
        self.teamID = teamID
        self.email = email
        self.ownDeviceID = ownDeviceID
        self.ownInstanceTag = ownInstanceTag
        self.allowsLoopback = allowsLoopback
    }

    /// Opens a tag-isolated SQLite store and binds operations to the supplied account scope.
    public convenience init(
        databaseURL: URL, runtime: any MobileSyncRuntime,
        userID: String, teamID: String?, email: String?,
        ownDeviceID: String, ownInstanceTag: String, allowsLoopback: Bool
    ) throws {
        self.init(
            store: try MobilePairedMacStore(databaseURL: databaseURL), runtime: runtime,
            userID: userID, teamID: teamID, email: email,
            ownDeviceID: ownDeviceID, ownInstanceTag: ownInstanceTag, allowsLoopback: allowsLoopback
        )
    }

    /// Loads only this exact account/team scope; an older read cannot overwrite a newer one.
    @discardableResult
    public func load() async throws -> [HivePairedComputer] {
        try checkCurrent()
        loadGeneration &+= 1
        let generation = loadGeneration
        let records: [MobilePairedMac]
        do { records = try await store.loadAll(stackUserID: userID, teamID: teamID) }
        catch { throw HivePairingError.storageFailed }
        try checkCurrent()
        let loaded = records.filter { $0.stackUserID == userID && $0.teamID == teamID }
            .compactMap(HivePairedComputer.init)
        if generation == loadGeneration {
            computers = loaded
            onChange?()
        }
        return loaded
    }

    /// Authenticates an explicitly entered destination before persisting its exact endpoint grant.
    public func pair(_ input: String) async throws -> HivePairedComputer {
        try checkCurrent()
        guard !isPairing else { throw HivePairingError.busy }
        isPairing = true
        defer { isPairing = false }
        let request = try HivePairingRequest(input: input, userID: userID, email: email, allowsLoopback: allowsLoopback)
        let runtime = runtime
        let client = MobileCoreRPCClient(
            runtime: runtime, route: request.route, ticket: request.ticket,
            allowsStackAuthFallback: request.route.kind == .debugLoopback,
            userTailscalePairingAuthorization: request.authorization,
            sessionPurpose: .probe
        )
        self.client = client
        do {
            let exchange = try await client.sendRequestAndAuthenticatedHostStatus(
                MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds,
                hostStatusTimeoutNanoseconds: { runtime.pairingRequestTimeoutNanoseconds }
            )
            try checkCurrent()
            let status = try MobileHostStatusResponse.decode(exchange.hostStatusResponse)
            let identity = try request.verifiedIdentity(
                status: status, ownDeviceID: ownDeviceID, ownInstanceTag: ownInstanceTag
            )
            do {
                let store = store
                let userID = userID
                let teamID = teamID
                let task = Task {
                    try await store.upsertWithUserTailscaleAuthorization(
                        macDeviceID: identity.macDeviceID, displayName: status.macDisplayName,
                        routes: [request.route], instanceTag: identity.instanceTag,
                        markActive: false, stackUserID: userID, teamID: teamID, now: runtime.now()
                    )
                }
                persistenceTask = task
                defer { persistenceTask = nil }
                try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } catch { throw HivePairingError.storageFailed }
            try checkCurrent()
            let loaded = try await load()
            guard let computer = loaded.first(where: { $0.id == identity.id }) else {
                throw HivePairingError.missingIdentity
            }
            await client.disconnect()
            self.client = nil
            try checkCurrent()
            return computer
        } catch {
            await client.disconnect()
            self.client = nil
            try checkCurrent()
            throw error
        }
    }

    /// Deletes one exact tagged pairing and revokes the live projection after storage confirms deletion.
    public func unpair(id: String) async throws {
        try checkCurrent()
        guard !isPairing else { throw HivePairingError.busy }
        // Unpairing is a pairing mutation: hold the same lock so a pair that
        // starts while the delete is suspended on store I/O cannot persist a
        // grant that the in-flight delete or the following load then drops.
        isPairing = true
        defer { isPairing = false }
        guard let computer = computers.first(where: { $0.id == id }) else { return }
        loadGeneration &+= 1
        do {
            try await store.removeExactScope(
                macDeviceID: computer.deviceID, instanceTag: computer.instanceTag,
                stackUserID: userID, teamID: teamID
            )
        } catch { throw HivePairingError.storageFailed }
        computers.removeAll { $0.id == id }
        onChange?()
        try await load()
    }

    /// Cancels the account's active handshake and clears its in-memory connection authority.
    @discardableResult
    public func stop() -> Task<Void, Never> {
        if isStopped { return disconnectTask ?? Task<Void, Never> {} }
        isStopped = true
        loadGeneration &+= 1
        computers = []
        persistenceTask?.cancel()
        let client = client
        self.client = nil
        client?.retire()
        let persistence = persistenceTask
        disconnectTask = Task {
            _ = try? await persistence?.value
            await client?.disconnect()
        }
        onChange?()
        return disconnectTask!
    }

    deinit {
        disconnectTask?.cancel()
        persistenceTask?.cancel()
    }

    private func checkCurrent() throws {
        try Task.checkCancellation()
        guard !isStopped else { throw HivePairingError.stopped }
    }
}
