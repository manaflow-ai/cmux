public import Foundation

/// One holder for one account scope. All login, access and refresh requests are
/// serialized through the private broker process, so no VM can race its rotating
/// Codex auth cache.
public actor CloudCodexBroker {
    public static let accessPath = "/home/cmux/.config/cmux/codex-broker/access.json"
    public static let modePath = "/home/cmux/.config/cmux/agent-auth/codex"
    public static let protocolVersion = 1

    private let scope: CloudCodexBrokerScope
    private let currentScope: @Sendable () async -> CloudCodexBrokerScope?
    private let executable: URL
    private let executablePrefix: [String]
    private let codexExecutable: URL
    private let home: URL
    private var session: CodexBrokerSession?
    private var stopped = false
    private var cached: CloudCodexAccessGrant?
    private var previousModeByMachine: [String: Data?] = [:]
    private var loadedPreviousMode: Set<String> = []
    private var installedAccess: [String: Data] = [:]
    private var uncertainInstallations: [String: (prior: Data?, candidate: Data)] = [:]
    private var pendingStageFiles: [String: Set<String>] = [:]
    private var accessRemovalAttempted: Set<String> = []
    private var targets: [String: CloudCodexBrokerTarget] = [:]
    private var targetGenerations: [String: Int] = [:]
    private var pendingRevocations: Set<String> = []
    private var revocationTargets: [String: CloudCodexBrokerTarget] = [:]
    private var targetLocks: Set<String> = []
    private var targetWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshCycle = 0
    private var refreshInFlight: Task<CloudCodexAccessGrant, any Error>?
    private var quitWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var quitTimers: [UUID: Task<Void, Never>] = [:]
    private var quitWork: [UUID: Task<Void, Never>] = [:]

    public init(scope: CloudCodexBrokerScope,
                currentScope: @escaping @Sendable () async -> CloudCodexBrokerScope?,
                executable: URL,
                executablePrefix: [String] = [],
                codexExecutable: URL,
                home: URL) {
        self.scope = scope
        self.currentScope = currentScope
        self.executable = executable
        self.executablePrefix = executablePrefix
        self.codexExecutable = codexExecutable
        self.home = home
    }

    deinit { refreshTask?.cancel() }

    /// Starts the browser device-code flow. The caller displays this prompt in
    /// cmux and then calls `waitForLogin` without opening a VM terminal.
    public func login(target: CloudCodexBrokerTarget, confirmed: Bool) async throws -> CloudCodexLoginPrompt {
        try await validate(target: target, confirmed: confirmed)
        try await ensureScope()
        let response = try await request(method: "login")
        try await ensureScope()
        guard let urlString = response.verificationURL,
              let url = URL(string: urlString), url.scheme == "https",
              let code = response.userCode, !code.isEmpty, code.utf8.count < 64 else {
            throw CloudCodexBrokerError.invalidReply
        }
        return CloudCodexLoginPrompt(verificationURL: url, userCode: code)
    }

    /// Polls the local holder after the person completes the browser flow, then
    /// delivers access-only JSON to this VM. The VM never receives a refresh seed.
    public func waitForLoginAndTransfer(target: CloudCodexBrokerTarget, confirmed: Bool,
                                        timeout: Duration = .seconds(300)) async throws -> CloudCodexAccessGrant {
        do {
            let generation = targetGenerations[target.machineID, default: 0]
            try await validate(target: target, confirmed: confirmed)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                guard !pendingRevocations.contains(target.machineID), targetGenerations[target.machineID, default: 0] == generation else { throw CloudCodexBrokerError.cancelled }
                do {
                    return try await transfer(target: target, confirmed: confirmed, forceRefresh: true)
                } catch CloudCodexBrokerError.notAuthenticated {
                    // wakeup-allow: bounded device-login polling while the private broker completes browser auth.
                    try await clock.sleep(for: .seconds(2))
                } catch CloudCodexBrokerError.brokerUnavailable {
                    throw CloudCodexBrokerError.brokerUnavailable
                } catch {
                    throw error
                }
            }
            throw CloudCodexBrokerError.cancelled
        } catch {
            let cleanup = Task { try? await self.revoke(target: target) }
            await cleanup.value
            throw error
        }
    }

    /// Reuses a cached short-lived access grant when possible; otherwise asks
    /// the local holder to refresh and writes only the new access token.
    public func transfer(target: CloudCodexBrokerTarget, confirmed: Bool,
                         forceRefresh: Bool = false) async throws -> CloudCodexAccessGrant {
        let generation = targetGenerations[target.machineID, default: 0]
        try await validate(target: target, confirmed: confirmed)
        try await ensureScope()
        guard !pendingRevocations.contains(target.machineID), targetGenerations[target.machineID, default: 0] == generation else { throw CloudCodexBrokerError.cancelled }
        targets[target.machineID] = target
        targetGenerations[target.machineID] = generation
        if !forceRefresh, let cached, cached.expiresAt > Date().addingTimeInterval(120) {
            try await deliver(cached, target: target, expectedGeneration: generation)
            return cached
        }
        let grant = try await refreshAccess(schedule: true)
        try await deliver(grant, target: target, expectedGeneration: generation)
        return grant
    }

    private func refreshAccess(schedule: Bool) async throws -> CloudCodexAccessGrant {
        if let refreshInFlight { return try await refreshInFlight.value }
        let task = Task { [weak self] () throws -> CloudCodexAccessGrant in
            guard let self else { throw CloudCodexBrokerError.brokerUnavailable }
            return try await self.performRefresh()
        }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        let grant = try await task.value
        if schedule { scheduleRefresh(grant: grant) }
        return grant
    }

    private func performRefresh() async throws -> CloudCodexAccessGrant {
        let response = try await request(method: "access", force: true, previousAccountID: cached?.chatgptAccountID)
        try await ensureScope()
        guard let token = response.accessToken, !token.isEmpty,
              let account = response.chatgptAccountID, !account.isEmpty,
              let expiry = response.expiresAt else { throw CloudCodexBrokerError.invalidReply }
        let grant = CloudCodexAccessGrant(accessToken: token, chatgptAccountID: account,
                                          expiresAt: Date(timeIntervalSince1970: expiry))
        guard grant.expiresAt > Date().addingTimeInterval(60) else { throw CloudCodexBrokerError.expiredAccess }
        cached = grant
        return grant
    }

    /// Revocation removes the delivered access file and own marker. The local
    /// refresh holder is signed out only when the caller explicitly requests it.
    public func revoke(target: CloudCodexBrokerTarget, signOut: Bool = false) async throws {
        let registered = targets.removeValue(forKey: target.machineID) != nil || pendingRevocations.contains(target.machineID)
        targetGenerations[target.machineID, default: 0] += 1
        guard registered else { return }
        pendingRevocations.insert(target.machineID)
        revocationTargets[target.machineID] = target
        await lockTarget(target.machineID)
        defer { unlockTarget(target.machineID) }
        if let stages = pendingStageFiles[target.machineID] {
            guard (try? await target.isLive()) == true else { throw CloudCodexBrokerError.targetOffline }
            for stage in stages.sorted() { try await target.removeFile(stage) }
            pendingStageFiles.removeValue(forKey: target.machineID)
        }
        // A registration awaiting its first grant owns no VM auth files.
        let uncertain = uncertainInstallations[target.machineID]
        guard installedAccess[target.machineID] != nil || uncertain != nil else {
            previousModeByMachine.removeValue(forKey: target.machineID)
            loadedPreviousMode.remove(target.machineID)
            accessRemovalAttempted.remove(target.machineID)
            pendingRevocations.remove(target.machineID)
            revocationTargets.removeValue(forKey: target.machineID)
            stopRenewalIfEmpty()
            if signOut, targets.isEmpty { _ = try? await request(method: "logout") }
            return
        }
        // Stop renewal without waking a paused VM. Its last access token remains
        // usable until provider expiry; file removal requires an online VM.
        guard (try? await target.isLive()) == true else {
            if targets.isEmpty {
                cached = nil
                refreshTask?.cancel()
                refreshTask = nil
                if signOut { _ = try? await request(method: "logout") }
            }
            throw CloudCodexBrokerError.targetOffline
        }
        let currentAccess = try await target.readFile(Self.accessPath)
        let installed = installedAccess[target.machineID]
        let knownCandidate = uncertain?.candidate
        let matchesOwnedInstallation = currentAccess != nil
            && (currentAccess == installed || currentAccess == knownCandidate)
        if (matchesOwnedInstallation || (currentAccess == nil && accessRemovalAttempted.contains(target.machineID))),
           try await target.readFile(Self.modePath) == Data("own\n".utf8) {
            accessRemovalAttempted.insert(target.machineID)
            if currentAccess != nil { try await target.removeFile(Self.accessPath) }
            if let previous = previousModeByMachine[target.machineID] ?? nil {
                try await target.writeFile(Self.modePath, previous, 0o600)
            } else { try await target.removeFile(Self.modePath) }
        }
        installedAccess.removeValue(forKey: target.machineID)
        uncertainInstallations.removeValue(forKey: target.machineID)
        accessRemovalAttempted.remove(target.machineID)
        previousModeByMachine.removeValue(forKey: target.machineID)
        loadedPreviousMode.remove(target.machineID)
        pendingRevocations.remove(target.machineID)
        revocationTargets.removeValue(forKey: target.machineID)
        if targets.isEmpty {
            cached = nil
            refreshTask?.cancel()
            refreshTask = nil
            if signOut { _ = try? await request(method: "logout") }
        }
    }

    private func stopRenewalIfEmpty() {
        guard targets.isEmpty else { return }
        cached = nil; refreshTask?.cancel(); refreshTask = nil
    }

    /// The server has confirmed deletion; there is no VM file left to restore.
    /// This is not a substitute for revocation of an existing machine.
    public func discardDeletedTarget(_ machineID: String) {
        targetGenerations[machineID, default: 0] += 1
        targets.removeValue(forKey: machineID)
        revocationTargets.removeValue(forKey: machineID)
        pendingRevocations.remove(machineID)
        previousModeByMachine.removeValue(forKey: machineID)
        installedAccess.removeValue(forKey: machineID)
        uncertainInstallations.removeValue(forKey: machineID)
        pendingStageFiles.removeValue(forKey: machineID)
        accessRemovalAttempted.remove(machineID)
        loadedPreviousMode.remove(machineID)
        if targets.isEmpty { cached = nil; refreshTask?.cancel(); refreshTask = nil }
    }

    private func validate(target: CloudCodexBrokerTarget, confirmed: Bool) async throws {
        guard !stopped else { throw CloudCodexBrokerError.cancelled }
        guard confirmed else { throw CloudCodexBrokerError.consentRequired }
        guard !pendingRevocations.contains(target.machineID) else { throw CloudCodexBrokerError.cancelled }
        guard await currentScope() == scope else { throw CloudCodexBrokerError.scopeChanged }
        guard try await target.isLive() else { throw CloudCodexBrokerError.targetOffline }
        let capability = try await target.capability()
        guard capability.ownerVM else { throw CloudCodexBrokerError.sharedMachine }
        guard capability.protocolVersion == Self.protocolVersion, capability.codexExternalAccessToken else {
            throw CloudCodexBrokerError.unsupportedMachine
        }
    }

    private func request(method: String, force: Bool? = nil, previousAccountID: String? = nil) async throws -> BrokerResult {
        guard !stopped || method == "logout" else { throw CloudCodexBrokerError.cancelled }
        if session == nil {
            session = try CodexBrokerSession(executable: executable, executablePrefix: executablePrefix, codexExecutable: codexExecutable, home: home)
        }
        guard let session else { throw CloudCodexBrokerError.brokerUnavailable }
        do {
            // concurrency-allow: the private broker request is off the UI actor and has a bounded cancellation race.
            return try await withThrowingTaskGroup(of: BrokerResult.self) { group in
                group.addTask { try await session.request(method: method, force: force, previousAccountID: previousAccountID) }
                group.addTask {
                    // wakeup-allow: hard bound for one private broker request
                    try await Task.sleep(for: .seconds(15))
                    throw CodexBrokerSession.Error.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CodexBrokerSession.Error.invalidReply }
                return result
            }
        } catch is CancellationError {
            await invalidate(session)
            throw CloudCodexBrokerError.cancelled
        } catch CodexBrokerSession.Error.notAuthenticated {
            throw CloudCodexBrokerError.notAuthenticated
        } catch CodexBrokerSession.Error.invalidReply {
            await invalidate(session)
            throw CloudCodexBrokerError.invalidReply
        } catch CodexBrokerSession.Error.accountChanged {
            throw CloudCodexBrokerError.accountChanged
        } catch {
            await invalidate(session)
            throw CloudCodexBrokerError.brokerUnavailable
        }
    }

    private func invalidate(_ failed: CodexBrokerSession) async {
        if session === failed { session = nil }
        await failed.shutdown()
    }

    private func deliver(_ grant: CloudCodexAccessGrant, target: CloudCodexBrokerTarget, expectedGeneration: Int? = nil) async throws {
        await lockTarget(target.machineID)
        defer { unlockTarget(target.machineID) }
        guard targets[target.machineID] != nil else { throw CloudCodexBrokerError.cancelled }
        let generation = expectedGeneration ?? targetGenerations[target.machineID, default: 0]
        guard !pendingRevocations.contains(target.machineID), targetGenerations[target.machineID, default: 0] == generation else { throw CloudCodexBrokerError.cancelled }
        let object: [String: Any] = [
            "schema": 1,
            "bridge": "codex-external-access-v1",
            "accessToken": grant.accessToken,
            "chatgptAccountId": grant.chatgptAccountID,
            "expiresAt": Int64(grant.expiresAt.timeIntervalSince1970),
            "installationID": UUID().uuidString,
        ]
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw CloudCodexBrokerError.invalidReply
        }
        let suffix = UUID().uuidString.lowercased()
        let stageAccess = "/home/cmux/.config/cmux/codex-broker/.access-\(suffix).json"
        let stageMode = "/home/cmux/.config/cmux/agent-auth/.codex-\(suffix)"
        var committed = false
        var commitAttempted = false
        let priorInstallation = installedAccess[target.machineID]
        do {
            try await validate(target: target, confirmed: true)
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation,
                  try await target.isLive() else { throw CloudCodexBrokerError.targetOffline }
            if !loadedPreviousMode.contains(target.machineID) {
                previousModeByMachine[target.machineID] = try await target.readFile(Self.modePath)
                loadedPreviousMode.insert(target.machineID)
            }
            try await ensureScope()
            try await target.makeDirectory("/home/cmux/.config")
            try await target.makeDirectory("/home/cmux/.config/cmux")
            try await target.makeDirectory("/home/cmux/.config/cmux/codex-broker")
            try await target.makeDirectory("/home/cmux/.config/cmux/agent-auth")
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
            pendingStageFiles[target.machineID, default: []].formUnion([stageAccess, stageMode])
            try await target.writeFile(stageAccess, data, 0o600)
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
            try await target.writeFile(stageMode, Data("own\n".utf8), 0o600)
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
            commitAttempted = true
            installedAccess[target.machineID] = data
            try await target.commitFiles(stageAccess, Self.accessPath, stageMode, Self.modePath)
            committed = true
            try await ensureScope()
            let stages = pendingStageFiles[target.machineID] ?? Set([stageAccess, stageMode])
            for stage in stages.sorted() { try await target.removeFile(stage) }
            pendingStageFiles.removeValue(forKey: target.machineID)
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
        } catch {
            var reconciliationFailed = false
            if commitAttempted, !committed {
                // Exec can commit and lose its reply. Reconcile independently
                // of caller cancellation; a unique installation ID binds it.
                let reconcile = Task { try await target.readFile(Self.accessPath) }
                do {
                    committed = try await reconcile.value == data
                    if !committed { installedAccess[target.machineID] = priorInstallation }
                } catch {
                    // Retain transport until revocation can reconcile this installation.
                    installedAccess[target.machineID] = priorInstallation
                    uncertainInstallations[target.machineID] = (prior: priorInstallation, candidate: data)
                    pendingRevocations.insert(target.machineID)
                    reconciliationFailed = true
                }
            }
            if committed || Task.isCancelled || error as? CloudCodexBrokerError == .scopeChanged {
                targets.removeValue(forKey: target.machineID)
                targetGenerations[target.machineID, default: 0] += 1
                pendingRevocations.insert(target.machineID)
                revocationTargets[target.machineID] = target
            }
            let previous = previousModeByMachine[target.machineID] ?? nil
            if committed { accessRemovalAttempted.insert(target.machineID) }
            // Cleanup must complete even when the initiating task was cancelled.
            let cleanup = Task {
                if let stages = pendingStageFiles[target.machineID], !stages.isEmpty {
                    for stage in stages.sorted() { try await target.removeFile(stage) }
                }
                if committed {
                    try await target.removeFile(Self.accessPath)
                    if let previous { try await target.writeFile(Self.modePath, previous, 0o600) }
                    else { try await target.removeFile(Self.modePath) }
                }
            }
            do {
                try await cleanup.value
                if committed {
                    installedAccess.removeValue(forKey: target.machineID)
                    accessRemovalAttempted.remove(target.machineID)
                }
                pendingStageFiles.removeValue(forKey: target.machineID)
            }
            catch { throw CloudCodexBrokerError.remoteDeliveryFailed }
            if reconciliationFailed { throw CloudCodexBrokerError.remoteDeliveryFailed }
            throw error as? CloudCodexBrokerError ?? (Task.isCancelled ? .cancelled : .remoteDeliveryFailed)
        }
    }

    private func lockTarget(_ machineID: String) async {
        if targetLocks.insert(machineID).inserted { return }
        await withCheckedContinuation { targetWaiters[machineID, default: []].append($0) }
    }

    private func unlockTarget(_ machineID: String) {
        if var waiters = targetWaiters[machineID], !waiters.isEmpty {
            let first = waiters.removeFirst()
            targetWaiters[machineID] = waiters
            first.resume()
        } else {
            targetLocks.remove(machineID)
            targetWaiters.removeValue(forKey: machineID)
        }
    }

    private func ensureScope() async throws {
        guard !stopped else { throw CloudCodexBrokerError.cancelled }
        guard await currentScope() == scope else { throw CloudCodexBrokerError.scopeChanged }
        guard !Task.isCancelled else { throw CloudCodexBrokerError.cancelled }
    }

    func registeredMachineIDs() -> Set<String> { Set(targets.keys) }

    /// Stops the local process and renewal before erasing registered VM files.
    /// Returns failed cleanup IDs; retained local credentials allow reuse later.
    public func shutdown() async -> Set<String> {
        stopped = true
        refreshTask?.cancel()
        refreshInFlight?.cancel()
        let endingTargets = Array(targets.merging(revocationTargets) { _, pending in pending }.values)
        if let session { await invalidate(session) }
        var failed = pendingRevocations
        await withTaskGroup(of: (String, Bool).self) { group in
            for target in endingTargets {
                group.addTask { [weak self] in
                    guard let self else { return (target.machineID, false) }
                    let succeeded: Bool
                    do { try await self.revokeWithinQuitBudget(target); succeeded = true }
                    catch { succeeded = false }
                    return (target.machineID, succeeded)
                }
            }
            for await (machineID, succeeded) in group {
                if succeeded { failed.remove(machineID) } else { failed.insert(machineID) }
            }
        }
        cached = nil
        return failed
    }

    private func revokeWithinQuitBudget(_ target: CloudCodexBrokerTarget) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            quitWaiters[id] = continuation
            // A timed-out transport may finish later. Its broker stays retained,
            // preventing replacement until that cleanup has actually completed.
            quitWork[id] = Task {
                do { try await revoke(target: target); finishQuitCleanup(id, .success(())) }
                catch { finishQuitCleanup(id, .failure(error)) }
                quitWork.removeValue(forKey: id)
            }
            quitTimers[id] = Task {
                // wakeup-allow: one bounded quit-cleanup deadline per target.
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                // Bound the caller's wait, not the remote mutation: cancellation
                // could release its lock before the server finishes erasing.
                finishQuitCleanup(id, .failure(CloudCodexBrokerError.remoteDeliveryFailed))
            }
        }
    }

    @discardableResult private func finishQuitCleanup(_ id: UUID, _ result: Result<Void, any Error>) -> Bool {
        guard let waiter = quitWaiters.removeValue(forKey: id) else { return false }
        quitTimers.removeValue(forKey: id)?.cancel()
        waiter.resume(with: result)
        return true
    }

    private func targetList() -> [CloudCodexBrokerTarget] { targets.values.sorted { $0.machineID < $1.machineID } }

    private func scheduleRefresh(grant: CloudCodexAccessGrant) {
        // A foreground force-refresh can race a renewal fan-out. Keep the
        // active renewal task alive so its target delivery is not cancelled and
        // misclassified as a revoked target. The existing task will schedule
        // itself again after its fan-out; a completed failed task clears its
        // handle in the catch below.
        guard refreshTask == nil, !targets.isEmpty else { return }
        refreshCycle += 1
        let cycle = refreshCycle
        let wait = max(1, grant.expiresAt.timeIntervalSinceNow - 120)
        let expectedScope = scope
        refreshTask = Task { [weak self] in
            do {
                // wakeup-allow: one renewal wakeup before the short-lived grant expires
                try await Task.sleep(for: .seconds(wait))
                guard let self else { return }
                guard await self.currentScope() == expectedScope else { throw CloudCodexBrokerError.scopeChanged }
                let refreshed = try await self.retryRenewal { try await self.refreshAccess(schedule: false) }
                let targets = await self.targetList()
                for target in targets {
                    do { try await self.retryRenewal { try await self.deliver(refreshed, target: target) } }
                    catch CloudCodexBrokerError.scopeChanged { throw CloudCodexBrokerError.scopeChanged }
                    catch { continue }
                }
                await self.rescheduleRefresh(after: refreshed, cycle: cycle)
            } catch {
                // cancellation, logout, or a stopped VM ends renewal; do not
                // leave a completed task handle blocking future scheduling.
                if let self { await self.finishRefreshTask(cycle: cycle) }
            }
        }
    }

    private func retryRenewal<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        for attempt in 0...3 {
            do { return try await work() }
            catch {
                guard !Task.isCancelled, attempt < 3,
                      let failure = error as? CloudCodexBrokerError,
                      [CloudCodexBrokerError.brokerUnavailable, .remoteDeliveryFailed, .expiredAccess].contains(failure) else { throw error }
                try await ensureScope()
                // wakeup-allow: at most three recovery attempts for an active renewal, then stop.
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        throw CloudCodexBrokerError.brokerUnavailable
    }

    private func finishRefreshTask(cycle: Int) {
        guard cycle == refreshCycle else { return }
        refreshTask = nil
    }

    private func rescheduleRefresh(after grant: CloudCodexAccessGrant, cycle: Int) {
        guard cycle == refreshCycle else { return }
        // This method runs on the renewal task itself; clear its handle before
        // installing the next one so scheduleRefresh cannot cancel this task.
        refreshTask = nil
        guard !Task.isCancelled, !targets.isEmpty else { return }
        scheduleRefresh(grant: cached ?? grant)
    }

}

/// Reuses one holder actor for each signed-in user/team scope. A VM target is
/// passed to transfer per call, while the rotating local refresh cache remains one per scope.
public actor CloudCodexBrokerRegistry {
    private var brokers: [CloudCodexBrokerScope: CloudCodexBroker] = [:]
    private var pendingCleanup: [CloudCodexBrokerScope: CloudCodexBroker] = [:]

    public init() {}

    public func broker(for scope: CloudCodexBrokerScope,
                       currentScope: @escaping @Sendable () async -> CloudCodexBrokerScope?,
                       executable: URL,
                       executablePrefix: [String] = [],
                       codexExecutable: URL,
                       home: URL) async throws -> CloudCodexBroker {
        if let previous = pendingCleanup[scope] {
            guard await previous.shutdown().isEmpty else { throw CloudCodexBrokerError.remoteDeliveryFailed }
            pendingCleanup.removeValue(forKey: scope)
        }
        if let broker = brokers[scope] { return broker }
        let broker = CloudCodexBroker(scope: scope, currentScope: currentScope, executable: executable,
                                      executablePrefix: executablePrefix, codexExecutable: codexExecutable, home: home)
        brokers[scope] = broker
        return broker
    }

    /// Returns the existing holder without creating or signing in to one.
    public func existing(for scope: CloudCodexBrokerScope) -> CloudCodexBroker? { brokers[scope] }

    func hasPendingCleanup(for scope: CloudCodexBrokerScope) -> Bool { pendingCleanup[scope] != nil }

    /// Called only after the service successfully deletes this VM.
    public func discardDeletedTarget(_ machineID: String, scope: CloudCodexBrokerScope) async {
        await brokers[scope]?.discardDeletedTarget(machineID)
        await pendingCleanup[scope]?.discardDeletedTarget(machineID)
    }

    /// Stops a scoped holder before releasing it. Credentials remain on disk.
    public func remove(scope: CloudCodexBrokerScope) async -> Set<String> {
        guard let broker = brokers.removeValue(forKey: scope) ?? pendingCleanup[scope] else { return [] }
        pendingCleanup[scope] = broker
        let failed = await broker.shutdown()
        if failed.isEmpty { pendingCleanup.removeValue(forKey: scope) }
        return failed
    }
}

