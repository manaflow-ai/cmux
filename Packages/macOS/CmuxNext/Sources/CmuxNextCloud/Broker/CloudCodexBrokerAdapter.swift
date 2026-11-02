public import Foundation
import CryptoKit
import Observation

/// App-lifetime coordinator for confirmed Codex access delivery. The app supplies
/// paths, executable discovery, current account scope, and its native prompt.
@MainActor @Observable public final class CloudCodexBrokerAdapter {
    /// Resolved local tools. `prefix` supports a bundled multicall executable.
    nonisolated public struct Launch: Sendable {
        public let executable: URL
        public let prefix: [String]
        public let codex: URL
        public init(executable: URL, prefix: [String], codex: URL) {
            self.executable = executable; self.prefix = prefix; self.codex = codex
        }
    }

    /// VMs whose delivered file could not be erased (for example, paused VMs).
    /// Renewal is stopped regardless; issued access expires at the provider.
    public var pendingCleanup: Set<String> { Set(cleanupByScope.values.flatMap { $0 }) }
    private var cleanupByScope: [CloudCodexBrokerScope: Set<String>] = [:]
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let registry: CloudCodexBrokerRegistry
    @ObservationIgnored private let currentScope: @MainActor @Sendable () -> CloudCodexBrokerScope?
    @ObservationIgnored private let launch: @Sendable () async throws -> Launch
    @ObservationIgnored private let target: @MainActor (CloudCodexBrokerScope, String) -> CloudCodexBrokerTarget
    @ObservationIgnored private var scopes: Set<CloudCodexBrokerScope> = []
    @ObservationIgnored private var runs: [UUID: (CloudCodexBrokerScope, String, Task<Void, any Error>)] = [:]
    @ObservationIgnored private var cleanupWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    @ObservationIgnored private var cleanupTimers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cleanupWork: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var teardownTasks: [CloudCodexBrokerScope: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeScopes: Set<CloudCodexBrokerScope> = []
    @ObservationIgnored private var scopeWaiters: [CloudCodexBrokerScope: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var signingOutScope: CloudCodexBrokerScope?
    /// Policy availability is an immediate fence. The holder teardown runs
    /// asynchronously, but new requests and in-flight writes observe this flag
    /// through the scope callback before they can commit a VM file.
    public private(set) var available = true

    /// Dependencies are injected; creating the adapter does not read credentials,
    /// start a process, or make a VM request.
    public init(root: URL, registry: CloudCodexBrokerRegistry,
                currentScope: @escaping @MainActor @Sendable () -> CloudCodexBrokerScope?,
                launch: @escaping @Sendable () async throws -> Launch,
                target: @escaping @MainActor (CloudCodexBrokerScope, String) -> CloudCodexBrokerTarget) {
        self.root = root; self.registry = registry; self.currentScope = currentScope
        self.launch = launch; self.target = target
    }

    /// Stable, opaque, unambiguous account/team namespace. Personal accounts and
    /// a team with an empty identifier remain distinct. Never imports ~/.codex.
    public func home(for scope: CloudCodexBrokerScope) -> URL {
        let fields = [scope.userID, scope.teamID == nil ? "personal" : "team", scope.teamID ?? ""]
        let encoded = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("codex-holders", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
    }

    /// Finishes one confirmed transfer, showing a native device-code prompt only
    /// when the local holder needs its first login. No VM terminal is opened.
    public func run(machineID: String, scope: CloudCodexBrokerScope, confirmed: Bool, forceRefresh: Bool = false,
                    presentDeviceCode: @escaping @MainActor @Sendable (CloudCodexLoginPrompt) async -> Bool) async throws {
        guard confirmed else { throw CloudCodexBrokerError.consentRequired }
        try check(scope)
        await scopeDidChange()
        try check(scope)
        let resolved = try await launch()
        try check(scope)
        if let teardown = teardownTasks[scope] { await teardown.value }
        try check(scope)
        let current = currentScope
        let availability: @MainActor @Sendable () -> CloudCodexBrokerScope? = { [weak self] in
            guard let self, self.available else { return nil }
            return current()
        }
        let retryingRetiredHolder = await registry.hasPendingCleanup(for: scope)
        let broker = try await registry.broker(for: scope, currentScope: { await availability() },
            executable: resolved.executable, executablePrefix: resolved.prefix,
            codexExecutable: resolved.codex, home: home(for: scope))
        if retryingRetiredHolder { cleanupByScope.removeValue(forKey: scope) }
        try check(scope)
        scopes.insert(scope)
        let vm = target(scope, machineID)
        let id = UUID()
        let task = Task {
            await self.lockScope(scope)
            defer { self.unlockScope(scope) }
            try self.check(scope)
            do {
                do { _ = try await broker.transfer(target: vm, confirmed: true, forceRefresh: forceRefresh) }
                catch CloudCodexBrokerError.notAuthenticated {
                    let prompt = try await broker.login(target: vm, confirmed: true)
                    try self.check(scope)
                    guard await presentDeviceCode(prompt) else { throw CloudCodexBrokerError.cancelled }
                    try self.check(scope)
                    _ = try await broker.waitForLoginAndTransfer(target: vm, confirmed: true)
                }
                try self.check(scope)
            } catch {
                // Settle failure before the next scoped transfer can register.
                do { try await self.revokeAfterFailure(broker, target: vm) }
                catch { self.cleanupByScope[scope, default: []].insert(machineID) }
                throw error
            }
        }
        runs[id] = (scope, machineID, task)
        defer { runs.removeValue(forKey: id) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try check(scope)
    }

    /// Account/team observations call this even when the user remains signed in.
    public func scopeDidChange() async {
        let keep = currentScope()
        if keep != signingOutScope { signingOutScope = nil }
        for scope in scopes where scope != keep { await retire(scope) }
    }

    /// Fences broker use immediately when Cloud policy is disabled. Re-enabling
    /// leaves the holder home on disk, so a later confirmed run can reuse its
    /// refresh credential without another device login.
    public func setAvailable(_ enabled: Bool) {
        guard enabled != available else { return }
        available = enabled
        guard !enabled else { return }
        for run in runs.values { run.2.cancel() }
        let retiring = scopes
        scopes.removeAll()
        for scope in retiring { beginRetirement(scope) }
    }

    /// Called before deleting/unregistering a VM, while its transport still exists.
    public func revoke(machineID: String, scope: CloudCodexBrokerScope) async throws {
        // End consent prompts and transfers before revoking their registration;
        // accepting a prompt later must not register this deleted VM again.
        for run in runs.values where run.0 == scope && run.1 == machineID { run.2.cancel() }
        guard scopes.contains(scope), let broker = await registry.existing(for: scope) else { return }
        do {
            try await broker.revoke(target: target(scope, machineID))
            cleanupByScope[scope]?.remove(machineID)
        } catch { cleanupByScope[scope, default: []].insert(machineID); throw error }
    }

    /// Only a successful server deletion may discard failed file cleanup.
    public func machineWasDeleted(_ machineID: String, scope: CloudCodexBrokerScope) async {
        for run in runs.values where run.0 == scope && run.1 == machineID { run.2.cancel() }
        await registry.discardDeletedTarget(machineID, scope: scope)
        cleanupByScope[scope]?.remove(machineID)
    }

    /// Stops all renewal/processes and tries to erase delivered files. Local
    /// rotating credentials are retained for the next explicit, confirmed use.
    public func shutdown() async {
        stopped = true
        for run in runs.values { run.2.cancel() }
        let retiring = scopes.union(teardownTasks.keys)
        for scope in retiring { beginRetirement(scope) }
        for scope in retiring { await teardownTasks[scope]?.value }
    }

    /// Ends account access before Cloud signs out, without permanently stopping
    /// this app's coordinator. Future confirmed runs can sign in again.
    public func signOut() async {
        signingOutScope = currentScope()
        for run in runs.values { run.2.cancel() }
        let retiring = scopes.union(teardownTasks.keys)
        for scope in retiring { beginRetirement(scope) }
        for scope in retiring { await teardownTasks[scope]?.value }
    }

    private func revokeAfterFailure(_ broker: CloudCodexBroker, target: CloudCodexBrokerTarget) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            cleanupWaiters[id] = continuation
            // Independent tasks do not inherit cancellation from the UI caller.
            cleanupWork[id] = Task {
                defer { cleanupWork.removeValue(forKey: id) }
                do { try await broker.revoke(target: target); finishCleanup(id, result: .success(())) }
                catch { finishCleanup(id, result: .failure(error)) }
            }
            cleanupTimers[id] = Task {
                // wakeup-allow: one-shot cleanup deadline, cancelled when revocation answers.
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                // Keep the native target lock until the remote mutation answers.
                // Cancellation may only stop waiting, not the server-side delete.
                finishCleanup(id, result: .failure(CloudCodexBrokerError.remoteDeliveryFailed))
            }
        }
    }

    @discardableResult private func finishCleanup(_ id: UUID, result: Result<Void, any Error>) -> Bool {
        guard let continuation = cleanupWaiters.removeValue(forKey: id) else { return false }
        cleanupTimers.removeValue(forKey: id)?.cancel()
        continuation.resume(with: result)
        return true
    }

    private func beginRetirement(_ scope: CloudCodexBrokerScope) {
        guard teardownTasks[scope] == nil else { return }
        for run in runs.values where run.0 == scope { run.2.cancel() }
        scopes.remove(scope)
        // Keep the barrier visible until teardown completes. Every concurrent
        // caller must await the same task before opening a replacement holder.
        teardownTasks[scope] = Task { [registry] in
            cleanupByScope[scope] = await registry.remove(scope: scope)
            teardownTasks.removeValue(forKey: scope)
        }
    }

    private func lockScope(_ scope: CloudCodexBrokerScope) async {
        if activeScopes.insert(scope).inserted { return }
        await withCheckedContinuation { scopeWaiters[scope, default: []].append($0) }
    }

    private func unlockScope(_ scope: CloudCodexBrokerScope) {
        guard var waiters = scopeWaiters[scope], !waiters.isEmpty else {
            activeScopes.remove(scope)
            scopeWaiters.removeValue(forKey: scope)
            return
        }
        let next = waiters.removeFirst()
        scopeWaiters[scope] = waiters
        next.resume()
    }

    private func retire(_ scope: CloudCodexBrokerScope) async {
        beginRetirement(scope)
        await teardownTasks[scope]?.value
    }

    private func check(_ scope: CloudCodexBrokerScope) throws {
        guard !stopped, available, signingOutScope != scope, !Task.isCancelled else { throw CloudCodexBrokerError.cancelled }
        guard currentScope() == scope else { throw CloudCodexBrokerError.scopeChanged }
    }
}
