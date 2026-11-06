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
    /// The machines this holder delivered to, on disk, so the next run renews or erases them.
    private let record: CloudCodexDeliveryRecord
    private var holderIDValue: String?
    /// When the scheduled renewal runs; a machine taken back whose access ends sooner renews at once.
    private var nextRenewalAt: Date?
    private var session: CodexBrokerSession?
    private var stopped = false
    /// Set by ``detach()``: a quit or an update, after which delivered access stays where it is.
    private var detached = false
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
    /// Machines taken back after a relaunch whose catch-up delivery failed, each with the task that tries
    /// it again until its access ends (``retryCatchUp(_:generation:until:)``).
    private var catchUps: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var refreshCycle = 0
    /// The first wait before a failed renewal tries again; each failure after it doubles the wait, up
    /// to ``renewalRetryCap``.
    private let renewalRetryBase: Duration
    static let renewalRetryCap: Duration = .seconds(300)
    private var refreshInFlight: Task<CloudCodexAccessGrant, any Error>?
    /// The access the Mac's own Codex sign-in holds (``CloudCodexLocalAccess``), when the person allowed it;
    /// asked before the private holder, so a Mac signed in to Codex needs no device login. Read only.
    private var localSignIn: (@Sendable () async -> CloudCodexAccessGrant?)?
    /// Whether ``cached`` came from the Mac's own Codex: its renewal runs while a newer token from the Mac
    /// still qualifies (``CloudCodexLocalAccess/minimumLifetime``), not 2 minutes before the end.
    private var cachedIsLocal = false
    private var quitWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var quitTimers: [UUID: Task<Void, Never>] = [:]
    private var quitWork: [UUID: Task<Void, Never>] = [:]

    public init(scope: CloudCodexBrokerScope,
                currentScope: @escaping @Sendable () async -> CloudCodexBrokerScope?,
                executable: URL,
                executablePrefix: [String] = [],
                codexExecutable: URL,
                home: URL,
                renewalRetryBase: Duration = .seconds(15)) {
        self.renewalRetryBase = renewalRetryBase
        self.scope = scope
        self.currentScope = currentScope
        self.executable = executable
        self.executablePrefix = executablePrefix
        self.codexExecutable = codexExecutable
        self.home = home
        self.record = CloudCodexDeliveryRecord(home: home)
    }

    deinit {
        refreshTask?.cancel()
        for entry in catchUps.values { entry.task.cancel() }
    }

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
        if !forceRefresh, await cachedStillAllowed(), let cached, cached.expiresAt > Date().addingTimeInterval(120) {
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

    /// Sets where the Mac's own Codex access is read (``CloudCodexBrokerAdapter/localSignIn``).
    func setLocalSignIn(_ source: (@Sendable () async -> CloudCodexAccessGrant?)?) { localSignIn = source }
    /// Whether ``cached`` may still be delivered: a grant from the Mac's own Codex only while the person's
    /// yes stands (``localSignIn`` answers nil once it is taken back or managed) and the Mac still holds that
    /// same token. Else it is dropped, so nothing stale or of another account reaches another machine.
    private func cachedStillAllowed() async -> Bool {
        guard cachedIsLocal else { return true }
        // Only the very token the Mac holds now: another account, or a newer token, drops the cache.
        if let localSignIn, let current = await localSignIn(), current == cached { return true }
        cached = nil; cachedIsLocal = false
        return false
    }

    /// When the scheduled renewal runs (tests).
    var scheduledRenewal: Date? { nextRenewalAt }

    private func performRefresh() async throws -> CloudCodexAccessGrant {
        // The Mac's own Codex keeps its token fresh; cmux only reads it, so no second refresher ever
        // rotates the Mac's refresh token. Nothing usable there: the private holder, as before.
        // The same token again is no renewal: the Mac's Codex has not refreshed yet, so the holder is
        // asked, and a failed renewal tries the Mac again after its backoff.
        if let localSignIn, let grant = await localSignIn(), grant.accessToken != cached?.accessToken {
            try await ensureScope()
            if let previous = cached?.chatgptAccountID, previous != grant.chatgptAccountID { throw CloudCodexBrokerError.accountChanged }
            guard grant.expiresAt > Date().addingTimeInterval(60) else { throw CloudCodexBrokerError.expiredAccess }
            cached = grant
            cachedIsLocal = true
            return grant
        }
        let response = try await request(method: "access", force: true, previousAccountID: cached?.chatgptAccountID)
        try await ensureScope()
        guard let token = response.accessToken, !token.isEmpty,
              let account = response.chatgptAccountID, !account.isEmpty,
              let expiry = response.expiresAt else { throw CloudCodexBrokerError.invalidReply }
        let grant = CloudCodexAccessGrant(accessToken: token, chatgptAccountID: account,
                                          expiresAt: Date(timeIntervalSince1970: expiry))
        guard grant.expiresAt > Date().addingTimeInterval(60) else { throw CloudCodexBrokerError.expiredAccess }
        cached = grant
        cachedIsLocal = false
        return grant
    }

    /// Revocation removes the delivered access file and own marker. The local
    /// refresh holder is signed out only when the caller explicitly requests it.
    public func revoke(target: CloudCodexBrokerTarget, signOut: Bool = false) async throws {
        let registered = targets.removeValue(forKey: target.machineID) != nil || pendingRevocations.contains(target.machineID)
        targetGenerations[target.machineID, default: 0] += 1
        cancelCatchUp(target.machineID)
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
        // The machine is read back and holds none of this holder's access now.
        record.forget(target.machineID)
        if targets.isEmpty {
            cached = nil
            refreshTask?.cancel()
            refreshTask = nil
            if signOut { _ = try? await request(method: "logout") }
        }
    }

    private func stopRenewalIfEmpty() {
        guard targets.isEmpty else { return }
        cached = nil; refreshTask?.cancel(); refreshTask = nil; cancelCatchUps()
    }

    /// The server has confirmed deletion; there is no VM file left to restore.
    /// This is not a substitute for revocation of an existing machine.
    public func discardDeletedTarget(_ machineID: String) {
        targetGenerations[machineID, default: 0] += 1
        targets.removeValue(forKey: machineID)
        cancelCatchUp(machineID)
        revocationTargets.removeValue(forKey: machineID)
        pendingRevocations.remove(machineID)
        previousModeByMachine.removeValue(forKey: machineID)
        installedAccess.removeValue(forKey: machineID)
        uncertainInstallations.removeValue(forKey: machineID)
        pendingStageFiles.removeValue(forKey: machineID)
        accessRemovalAttempted.remove(machineID)
        loadedPreviousMode.remove(machineID)
        record.forget(machineID)
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
        var data = Data()
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
                previousModeByMachine[target.machineID] = try await Self.modeBeforeBroker(target)
                loadedPreviousMode.insert(target.machineID)
            }
            // The access file carries the mode to restore, so a later run of cmux revokes what an
            // earlier one left at quit (#33482) without mistaking its marker for the person's choice.
            let previous = previousModeByMachine[target.machineID] ?? nil
            let object: [String: Any] = [
                "schema": 1,
                "bridge": "codex-external-access-v1",
                "accessToken": grant.accessToken,
                "chatgptAccountId": grant.chatgptAccountID,
                "expiresAt": Int64(grant.expiresAt.timeIntervalSince1970),
                "installationID": UUID().uuidString,
                "holder": holderID(),
                "previousMode": previous.map { $0.base64EncodedString() } ?? NSNull(),
            ]
            guard JSONSerialization.isValidJSONObject(object),
                  let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                throw CloudCodexBrokerError.invalidReply
            }
            data = encoded
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
            // Recorded before the commit, so a quit or crash right after it still leaves a record.
            record.delivered(target.machineID)
            try await target.commitFiles(stageAccess, Self.accessPath, stageMode, Self.modePath)
            committed = true
            try await ensureScope()
            let stages = pendingStageFiles[target.machineID] ?? Set([stageAccess, stageMode])
            for stage in stages.sorted() { try await target.removeFile(stage) }
            pendingStageFiles.removeValue(forKey: target.machineID)
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
        } catch {
            // A quit cut this renewal short: whatever it committed stays, like every other delivery.
            if detached { throw CloudCodexBrokerError.cancelled }
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
                    record.forget(target.machineID)
                }
                pendingStageFiles.removeValue(forKey: target.machineID)
            }
            catch { throw CloudCodexBrokerError.remoteDeliveryFailed }
            if reconciliationFailed { throw CloudCodexBrokerError.remoteDeliveryFailed }
            throw error as? CloudCodexBrokerError ?? (Task.isCancelled ? .cancelled : .remoteDeliveryFailed)
        }
    }

    /// The machine's Codex mode before any broker delivery. An `own` marker under an access file
    /// this broker wrote is an earlier run's (one that quit and left it); its `previousMode` is the
    /// person's own. Any other `own`, including one under an older broker file that records none,
    /// is the person's choice (`cr use`, an agent login) and is kept.
    static func modeBeforeBroker(_ target: CloudCodexBrokerTarget) async throws -> Data? {
        let mode = try await target.readFile(modePath)
        guard mode == Data("own\n".utf8),
              let access = try await target.readFile(accessPath),
              let object = try? JSONSerialization.jsonObject(with: access) as? [String: Any],
              object["bridge"] as? String == "codex-external-access-v1",
              let recorded = object["previousMode"] else { return mode }
        if recorded is NSNull { return nil }
        guard let text = recorded as? String, let previous = Data(base64Encoded: text) else { return mode }
        return previous
    }

    /// After a relaunch: takes back a machine that an earlier run of cmux delivered access to and left
    /// at quit (``CloudCodexDeliveryRecord``). While the machine still holds that access under the `own`
    /// marker it registers again, as a delivery of this run would: renewal picks back up (cmux#33878)
    /// and a sign-out, an account or team switch or the off switch erases it (cmux#33877). With
    /// `erase` (an earlier ask to erase it could not reach the machine) it is erased now instead. A
    /// machine that holds none of this holder's access is forgotten; a paused one stays recorded.
    public func resume(target: CloudCodexBrokerTarget, erase: Bool) async {
        let id = target.machineID
        guard !stopped, targets[id] == nil, await currentScope() == scope,
              (try? await target.isLive()) == true else { return }
        if pendingRevocations.contains(id) {
            // An erase this run could not finish (the machine was paused): it is back, so finish it.
            try? await revoke(target: revocationTargets[id] ?? target)
            return
        }
        let generation = targetGenerations[id, default: 0]
        await lockTarget(id)
        let left: Data?
        do {
            guard !stopped, targets[id] == nil, !pendingRevocations.contains(id),
                  targetGenerations[id, default: 0] == generation else { unlockTarget(id); return }
            // Renewing needs the same owner check as a delivery; erasing only removes this holder's file.
            if !erase { try await validate(target: target, confirmed: true) }
            left = try await Self.accessLeftByBroker(target, holder: holderID())
            if left != nil {
                previousModeByMachine[id] = try await Self.modeBeforeBroker(target)
                loadedPreviousMode.insert(id)
            }
        } catch { unlockTarget(id); return }
        guard let left, !stopped, targetGenerations[id, default: 0] == generation else {
            if left == nil { record.forget(id) }
            previousModeByMachine.removeValue(forKey: id)
            loadedPreviousMode.remove(id)
            unlockTarget(id)
            return
        }
        installedAccess[id] = left
        targets[id] = target
        targetGenerations[id] = generation
        unlockTarget(id)
        if erase {
            // A failure keeps the record's erase mark, so a later pass tries again.
            try? await revoke(target: target)
            return
        }
        let leftExpiry = Self.grant(in: left).expiresAt
        let renewBy = leftExpiry.addingTimeInterval(-120)
        let cachedIsCurrent = cached.map { $0.expiresAt > Date().addingTimeInterval(120) } ?? false
        if cachedIsCurrent || (refreshTask != nil && nextRenewalAt.map { renewBy < $0 } == true) {
            // Renewal already runs for this holder and the machine joins it with the current grant, or
            // the scheduled renewal comes after this machine's access ends and it gets fresh access now.
            // A failure tries again until that access ends (cmux#34010).
            do { try await catchUp(target, generation: generation) }
            catch where Self.catchUpRetries(error) { retryCatchUp(target, generation: generation, until: leftExpiry) }
            catch {}
        } else {
            scheduleRefresh(grant: Self.grant(in: left))
        }
    }

    /// One catch-up delivery for a machine taken back after a relaunch: the cached grant while it is
    /// current, else a fresh one.
    private func catchUp(_ target: CloudCodexBrokerTarget, generation: Int) async throws {
        let grant: CloudCodexAccessGrant
        if await cachedStillAllowed(), let cached, cached.expiresAt > Date().addingTimeInterval(120) { grant = cached }
        else { grant = try await refreshAccess(schedule: true) }
        try await deliver(grant, target: target, expectedGeneration: generation)
    }

    /// Whether a failed catch-up tries again: what a renewal retries, and a machine paused for now.
    static func catchUpRetries(_ error: any Error) -> Bool {
        retriesLater(error) || error as? CloudCodexBrokerError == .targetOffline
    }

    /// Tries a failed catch-up again, after the renewal backoff (``renewalRetryDelay(_:)``), until the
    /// access the machine holds runs out at `expiry`; the last wait ends at `expiry`. Before cmux#34010 a
    /// failed catch-up was not tried again, and the machine's access could expire before the scheduled
    /// renewal reached it. Stops: a delivery lands, `expiry` passes, the machine's access already outlasts
    /// `expiry` (the scheduled renewal reached it), an error a renewal would not retry, or the machine is
    /// no longer this run's at `generation` (erased, signed out, deleted), the account or team changed,
    /// or the broker stopped. Cleanup: ``revoke(target:signOut:)``, ``discardDeletedTarget(_:)``,
    /// ``shutdown()``, ``detach()`` and an emptied target list cancel the task, and it removes its own
    /// entry in ``catchUps`` when it ends.
    private func retryCatchUp(_ target: CloudCodexBrokerTarget, generation: Int, until expiry: Date) {
        let id = target.machineID
        catchUps.removeValue(forKey: id)?.task.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            var failures = 0
            // wakeup-allow: each pass sleeps a backoff first and the loop ends at the machine's access expiry.
            while !Task.isCancelled {
                failures += 1
                guard let delay = await self?.catchUpDelay(failures, until: expiry) else { break }
                // wakeup-allow: bounded catch-up retries, backed off, that end when the machine's access expires.
                do { try await Task.sleep(for: delay) } catch { break }
                guard let self, await self.catchUpWanted(id, generation: generation, until: expiry) else { break }
                do { try await self.catchUp(target, generation: generation); break }
                catch { if !Self.catchUpRetries(error) { break } }
            }
            await self?.catchUpEnded(id, token: token)
        }
        catchUps[id] = (token, task)
    }

    /// The wait before catch-up try `failures`, never past `expiry`; nil once `expiry` has passed.
    private func catchUpDelay(_ failures: Int, until expiry: Date) -> Duration? {
        let remaining = expiry.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return min(renewalRetryDelay(failures), .seconds(remaining))
    }

    private func catchUpWanted(_ id: String, generation: Int, until expiry: Date) async -> Bool {
        guard !stopped, targets[id] != nil, !pendingRevocations.contains(id),
              targetGenerations[id, default: 0] == generation, Date() < expiry,
              Self.grant(in: installedAccess[id] ?? Data()).expiresAt <= expiry else { return false }
        return await currentScope() == scope
    }

    private func catchUpEnded(_ id: String, token: UUID) {
        if catchUps[id]?.token == token { catchUps.removeValue(forKey: id) }
    }

    private func cancelCatchUp(_ id: String) { catchUps.removeValue(forKey: id)?.task.cancel() }

    private func cancelCatchUps() {
        for entry in catchUps.values { entry.task.cancel() }
        catchUps.removeAll()
    }

    /// The machines a failed catch-up still tries again for.
    func catchUpMachineIDs() -> Set<String> { Set(catchUps.keys) }

    /// The catch-up retry for `id`, if one runs, so a test can wait for it to end.
    func catchUpTask(_ id: String) -> Task<Void, Never>? { catchUps[id]?.task }

    /// The access file this holder's delivery left on `target` under the `own` marker, or nil when the
    /// machine holds none of it (the person signed Codex in some other way since, another Mac or
    /// account delivered over it, or nothing is there).
    static func accessLeftByBroker(_ target: CloudCodexBrokerTarget, holder: String) async throws -> Data? {
        guard try await target.readFile(modePath) == Data("own\n".utf8),
              let access = try await target.readFile(accessPath),
              let object = try? JSONSerialization.jsonObject(with: access) as? [String: Any],
              object["bridge"] as? String == "codex-external-access-v1",
              object["holder"] as? String == holder else { return nil }
        return access
    }

    private func holderID() -> String {
        if let holderIDValue { return holderIDValue }
        let id = record.holderID()
        holderIDValue = id
        return id
    }

    /// The grant a left access file carries; only its expiry is used, to time the next renewal. An
    /// unreadable one counts as expired, so renewal runs at once.
    static func grant(in access: Data) -> CloudCodexAccessGrant {
        let object = (try? JSONSerialization.jsonObject(with: access) as? [String: Any]) ?? [:]
        let expiry = (object["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return CloudCodexAccessGrant(accessToken: object["accessToken"] as? String ?? "",
                                     chatgptAccountID: object["chatgptAccountId"] as? String ?? "",
                                     expiresAt: Date(timeIntervalSince1970: expiry))
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
        cancelCatchUps()
        refreshInFlight?.cancel()
        let endingTargets = Array(targets.merging(revocationTargets) { _, pending in pending }.values)
        if let session { await invalidate(session) }
        let failed = await revokeWithinQuitBudget(endingTargets, failed: pendingRevocations)
        cached = nil
        return failed
    }

    /// Quit and update: stops renewal and the local process like ``shutdown()``, but leaves the
    /// access delivered to each registered VM in place until the provider expires it, so a Cloud
    /// Codex run keeps working after cmux quits or updates (#33482). Only revocations asked for
    /// before the quit (a deleted machine, a failed delivery) still run, within the quit budget.
    /// Returns the IDs whose pending revocation failed.
    public func detach() async -> Set<String> {
        // Snapshot first: a renewal the cancel below cuts short is not an ask to erase.
        let asked = Array(revocationTargets.values)
        let pending = pendingRevocations
        stopped = true
        detached = true
        refreshTask?.cancel()
        refreshTask = nil
        cancelCatchUps()
        refreshInFlight?.cancel()
        if let session { await invalidate(session) }
        let failed = await revokeWithinQuitBudget(asked, failed: pending)
        cached = nil
        return failed
    }

    private func revokeWithinQuitBudget(_ endingTargets: [CloudCodexBrokerTarget], failed initial: Set<String>) async -> Set<String> {
        var failed = initial
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

    /// Renews `grant` before it expires. `failures` counts the renewals that failed in a row: after
    /// one the next try comes after a backoff instead (``renewalRetryDelay(_:)``).
    private func scheduleRefresh(grant: CloudCodexAccessGrant, failures: Int = 0) {
        // A foreground force-refresh can race a renewal fan-out. Keep the
        // active renewal task alive so its target delivery is not cancelled and
        // misclassified as a revoked target. The existing task will schedule
        // itself again after its fan-out; a completed failed task clears its
        // handle in the catch below.
        guard refreshTask == nil, !targets.isEmpty, !stopped else { return }
        refreshCycle += 1
        let cycle = refreshCycle
        let lead = cachedIsLocal && grant == cached ? CloudCodexLocalAccess.minimumLifetime + 60 : 120
        let wait: Duration = failures == 0 ? .seconds(max(1, grant.expiresAt.timeIntervalSinceNow - lead)) : renewalRetryDelay(failures)
        nextRenewalAt = Date().addingTimeInterval(Double(wait.components.seconds))
        let expectedScope = scope
        refreshTask = Task { [weak self] in
            do {
                // wakeup-allow: one renewal wakeup before the short-lived grant expires, or one backoff after a failed renewal
                try await Task.sleep(for: wait)
                guard let self else { return }
                guard await self.currentScope() == expectedScope else { throw CloudCodexBrokerError.scopeChanged }
                let refreshed = try await self.retryRenewal { try await self.refreshAccess(schedule: false) }
                let targets = await self.targetList()
                var undelivered: (any Error)?
                for target in targets {
                    do { try await self.retryRenewal { try await self.deliver(refreshed, target: target) } }
                    catch CloudCodexBrokerError.scopeChanged { throw CloudCodexBrokerError.scopeChanged }
                    catch { if Self.retriesLater(error) { undelivered = error } }
                }
                // A machine its VM API failed to reach keeps its old access, which expires before the
                // refreshed grant's renewal: it takes the backoff instead (cmux#33387).
                if let undelivered { throw undelivered }
                await self.rescheduleRefresh(after: refreshed, cycle: cycle)
            } catch {
                // cancellation, logout, or a stopped VM ends renewal; do not
                // leave a completed task handle blocking future scheduling.
                // A transient failure (the Mac woke before its network did, Wi-Fi dropped) tries again later.
                if let self { await self.renewalFailed(error, grant: grant, cycle: cycle, failures: failures) }
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

    /// A renewal that failed: it ends, and after a transient failure the next one is scheduled after a
    /// backoff. Renewal used to end for good after its three quick retries (7 s), so a Mac that woke from
    /// sleep at a renewal before its Wi-Fi was back never renewed again, and the Cloud machine's Codex
    /// lost its access once the grant expired. Stops: the broker shut down, no target left, a newer
    /// renewal, the account or team changed, Codex signed out, or the task cancelled.
    private func renewalFailed(_ error: any Error, grant: CloudCodexAccessGrant, cycle: Int, failures: Int) {
        finishRefreshTask(cycle: cycle)
        guard cycle == refreshCycle, !Task.isCancelled, Self.retriesLater(error) else { return }
        scheduleRefresh(grant: cached ?? grant, failures: failures + 1)
    }

    /// Whether a failed renewal tries again later: the local holder or a delivery failed, including the
    /// holder's `codex_auth_unavailable` (``CloudCodexBrokerError/notAuthenticated``), which is also what an
    /// offline refresh answers (the holder maps every refresh error but an account change to it, so a
    /// sign-out and a network failure look alike; retrying a signed-out holder only asks it again, locally).
    /// Never an account or team change, or a cancel.
    static func retriesLater(_ error: any Error) -> Bool {
        guard let failure = error as? CloudCodexBrokerError else { return false }
        return [CloudCodexBrokerError.brokerUnavailable, .remoteDeliveryFailed, .expiredAccess, .invalidReply, .notAuthenticated].contains(failure)
    }

    /// The wait before renewal try `failures` (1 or more): the base, doubled per failure, capped.
    func renewalRetryDelay(_ failures: Int) -> Duration {
        min(renewalRetryBase * (1 << min(max(failures - 1, 0), 10)), Self.renewalRetryCap)
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

