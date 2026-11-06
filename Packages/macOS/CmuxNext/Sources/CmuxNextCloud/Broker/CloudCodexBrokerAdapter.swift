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
    /// The pass ``machinesListed(_:)`` started; one at a time.
    @ObservationIgnored private var resumePass: Task<Void, Never>?
    /// The scope seen last, so a switch retires it even before any pass registered it.
    @ObservationIgnored private var observedScope: CloudCodexBrokerScope?
    /// Policy availability is an immediate fence. The holder teardown runs
    /// asynchronously, but new requests and in-flight writes observe this flag
    /// through the scope callback before they can commit a VM file.
    public private(set) var available = true
    /// The Mac's own Codex access (``CloudCodexLocalAccess``), read only once the person allowed it
    /// (`cloud.useMyCodexLoginOnMyCloudMachines`); nil when it must not be read. Every holder asks it first.
    @ObservationIgnored public var localSignIn: (@Sendable () async -> CloudCodexAccessGrant?)?

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
    ///
    /// `askLocalSignIn` comes first when the holder has no login: the one-time consent to use the Mac's
    /// own Codex sign-in (true when it was given and the Mac has one), so no device code shows then.
    public func run(machineID: String, scope: CloudCodexBrokerScope, confirmed: Bool, forceRefresh: Bool = false,
                    askLocalSignIn: (@MainActor @Sendable () async -> Bool)? = nil,
                    presentDeviceCode: @escaping @MainActor @Sendable (CloudCodexLoginPrompt) async -> Bool) async throws {
        guard confirmed else { throw CloudCodexBrokerError.consentRequired }
        try check(scope)
        await scopeDidChange()
        try check(scope)
        let resolved = try await launch()
        try check(scope)
        if let teardown = teardownTasks[scope] { await teardown.value }
        try check(scope)
        let broker = try await openBroker(scope, resolved)
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
                    try self.check(scope)
                    if let askLocalSignIn, await askLocalSignIn() {
                        try self.check(scope)
                        if (try? await broker.transfer(target: vm, confirmed: true, forceRefresh: true)) != nil {
                            try self.check(scope)
                            return
                        }
                    }
                    try self.check(scope)
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

    /// Each machine list the app reads: ``resume(scope:liveMachineIDs:)`` for the signed-in scope and its
    /// live machines. One pass at a time; a list that lands during one is picked up by the next list.
    /// A machine the pass could not take back yet (a Worker machine whose owner link is still
    /// connecting) is tried again after 15, 30 and 60 s. Stops: every machine taken back, forgotten or
    /// erased, the third retry, or a quit, sign-out, switch or off switch (which cancel the pass).
    public func machinesListed(_ machines: [CloudMachine]) {
        guard resumePass == nil, let scope = currentScope() else { return }
        if observedScope == nil { observedScope = scope }
        let live = Set(machines.filter { $0.status.isLive }.map(\.id))
        resumePass = Task { [weak self] in
            var left = await self?.resume(scope: scope, liveMachineIDs: live) ?? []
            for delay in [15, 30, 60] where !left.isEmpty {
                // wakeup-allow: at most three bounded retries for machines whose owner link was not ready.
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                left = await self?.resume(scope: scope, liveMachineIDs: left) ?? []
            }
            self?.resumePass = nil
        }
    }

    /// After a relaunch, and after each machine list: takes back the machines in `liveMachineIDs` that
    /// an earlier run of cmux delivered Codex access to for `scope` (``CloudCodexDeliveryRecord``), so
    /// their renewal picks back up (cmux#33878) and a sign-out, a switch or the off switch erases them
    /// (cmux#33877). A machine whose erase an earlier run could not finish is erased instead. Asks no
    /// consent and shows no prompt: each was confirmed when it was first delivered to. Stops: a machine
    /// already registered is skipped, so a repeat pass does nothing.
    /// Returns the live recorded machines this pass could not take back or erase yet.
    @discardableResult
    public func resume(scope: CloudCodexBrokerScope, liveMachineIDs: Set<String>) async -> Set<String> {
        let record = CloudCodexDeliveryRecord(home: home(for: scope))
        let recorded = await Task.detached(priority: .utility) { record.entries() }.value
        guard !recorded.isEmpty else { return [] }
        if let teardown = teardownTasks[scope] { await teardown.value }
        guard (try? check(scope)) != nil else { return [] }
        // Recorded machines belong to this scope now, so its retirement marks every one for erasure.
        scopes.insert(scope)
        let wanted = recorded.filter { liveMachineIDs.contains($0.key) }
        guard !wanted.isEmpty, let resolved = try? await launch(), (try? check(scope)) != nil,
              let broker = try? await openBroker(scope, resolved), (try? check(scope)) != nil else { return [] }
        await lockScope(scope)
        defer { unlockScope(scope) }
        let registered = await broker.registeredMachineIDs()
        for (machineID, erase) in wanted.sorted(by: { $0.key < $1.key }) where !registered.contains(machineID) {
            guard (try? check(scope)) != nil else { return [] }
            await broker.resume(target: target(scope, machineID), erase: erase)
        }
        let still = await Task.detached(priority: .utility) { record.entries() }.value
        let taken = await broker.registeredMachineIDs()
        return Set(wanted.keys).filter { still[$0] != nil && !taken.contains($0) }
    }

    private func openBroker(_ scope: CloudCodexBrokerScope, _ resolved: Launch) async throws -> CloudCodexBroker {
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
        await broker.setLocalSignIn(localSignIn)
        return broker
    }

    /// Whether this scope's broker already delivers (and renews) access on `machineID`. A new chat's
    /// start leaves such a machine alone: a failed repeat transfer would revoke the access its other
    /// chats use (cmux#33489).
    public func delivers(machineID: String, scope: CloudCodexBrokerScope) async -> Bool {
        await registry.existing(for: scope)?.registeredMachineIDs().contains(machineID) ?? false
    }

    /// Account/team observations call this even when the user remains signed in.
    public func scopeDidChange() async {
        let keep = currentScope()
        if keep != signingOutScope { signingOutScope = nil }
        // A scope left before any pass registered it still erases what its record holds (cmux#33877).
        if let left = observedScope, left != keep { scopes.insert(left); resumePass?.cancel() }
        observedScope = keep
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
        resumePass?.cancel()
        if let scope = currentScope() { scopes.insert(scope) }
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
        resumePass?.cancel()
        let retiring = scopes.union(teardownTasks.keys)
        for scope in retiring { beginRetirement(scope) }
        for scope in retiring { await teardownTasks[scope]?.value }
    }

    /// Quit and update: stops renewal and the local broker processes, but each Cloud machine
    /// keeps the Codex access already delivered to it until the provider expires it, so an
    /// unattended Cloud Codex run outlives the quit (#33482). Sign-out, an account or team
    /// switch, the Cloud off switch and a machine delete still erase it.
    public func detachForQuit() async {
        stopped = true
        for run in runs.values { run.2.cancel() }
        resumePass?.cancel()
        // A sign-out or switch already under way erases, as it was asked to.
        for task in Array(teardownTasks.values) { await task.value }
        for scope in scopes {
            guard let broker = await registry.existing(for: scope) else { continue }
            let failed = await broker.detach()
            if !failed.isEmpty { cleanupByScope[scope, default: []].formUnion(failed) }
        }
    }

    /// Ends account access before Cloud signs out, without permanently stopping
    /// this app's coordinator. Future confirmed runs can sign in again.
    public func signOut() async {
        signingOutScope = currentScope()
        for run in runs.values { run.2.cancel() }
        resumePass?.cancel()
        // Retired even before any pass registered it, so what its record holds is erased (cmux#33877).
        if let scope = signingOutScope { scopes.insert(scope) }
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
        let record = CloudCodexDeliveryRecord(home: home(for: scope))
        teardownTasks[scope] = Task { [registry] in
            cleanupByScope[scope] = await registry.remove(scope: scope)
            // What is still recorded (a paused machine, one this run never reached) is erased by the
            // next pass that reaches it, never renewed (cmux#33877).
            await Task.detached(priority: .utility) { record.markAllForErasure() }.value
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
