public import Foundation

/// The account scope that owns one local Codex refresh-token holder. The scope is
/// captured when the broker is created and must not change while it serves VMs.
nonisolated public struct CloudCodexBrokerScope: Sendable, Equatable, Hashable {
    public let userID: String
    public let teamID: String?

    nonisolated public init(userID: String, teamID: String?) {
        self.userID = userID
        self.teamID = teamID
    }
}

/// A device-code response for the one-time Codex sign-in. The code is safe to
/// show in cmux; no credential or auth cache is included.
nonisolated public struct CloudCodexLoginPrompt: Sendable, Equatable {
    public let verificationURL: URL
    public let userCode: String

    nonisolated public init(verificationURL: URL, userCode: String) {
        self.verificationURL = verificationURL
        self.userCode = userCode
    }
}

/// The access-only credential delivered to a VM. The refresh token never enters
/// this value, the VM, a log, or a process argument.
nonisolated public struct CloudCodexAccessGrant: Sendable, Equatable {
    public let accessToken: String
    public let chatgptAccountID: String
    public let expiresAt: Date

    nonisolated public init(accessToken: String, chatgptAccountID: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.chatgptAccountID = chatgptAccountID
        self.expiresAt = expiresAt
    }
}

nonisolated public enum CloudCodexBrokerError: Error, LocalizedError, Sendable, Equatable {
    case consentRequired
    case scopeChanged
    case sharedMachine
    case unsupportedMachine
    case brokerUnavailable
    case notAuthenticated
    case loginRequired(CloudCodexLoginPrompt)
    case invalidReply
    case accountChanged
    case expiredAccess
    case targetOffline
    case remoteDeliveryFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .consentRequired: "Confirm that Codex access will be delivered to this VM."
        case .scopeChanged: "The signed-in account or team changed; start the transfer again."
        case .sharedMachine: "This VM is shared, so it cannot receive a personal Codex credential."
        case .unsupportedMachine: "This VM does not support Codex access delivery yet."
        case .brokerUnavailable: "The local Codex sign-in holder is unavailable."
        case .notAuthenticated: "Finish signing in to Codex to continue."
        case .loginRequired: "Sign in to Codex to continue."
        case .invalidReply, .accountChanged: "Codex sign-in could not be completed."
        case .expiredAccess: "Codex returned an expired access token."
        case .targetOffline: "This VM is offline or paused; resume it before delivering Codex access."
        case .remoteDeliveryFailed: "The Codex access token could not be delivered to this VM."
        case .cancelled: "Codex sign-in was cancelled."
        }
    }
}

/// A capability probe and the minimal file operations needed to deliver a
/// short-lived access token. The app server remains the only transport; this
/// abstraction keeps the broker testable and lets the VM bridge own its probe.
nonisolated public struct CloudCodexBrokerTarget: Sendable {
    nonisolated public struct Capability: Sendable, Equatable {
        public let ownerVM: Bool
        public let protocolVersion: Int
        public let codexExternalAccessToken: Bool

        nonisolated public init(ownerVM: Bool, protocolVersion: Int, codexExternalAccessToken: Bool) {
            self.ownerVM = ownerVM
            self.protocolVersion = protocolVersion
            self.codexExternalAccessToken = codexExternalAccessToken
        }
    }

    public let machineID: String
    /// A non-waking machine status check. Renewal must not resume a paused VM.
    public let isLive: @Sendable () async throws -> Bool
    public let capability: @Sendable () async throws -> Capability
    public let makeDirectory: @Sendable (String) async throws -> Void
    public let readFile: @Sendable (String) async throws -> Data?
    public let writeFile: @Sendable (String, Data, Int) async throws -> Void
    public let commitFiles: @Sendable (String, String, String, String) async throws -> Void
    public let removeFile: @Sendable (String) async throws -> Void

    nonisolated public init(machineID: String,
                capability: @escaping @Sendable () async throws -> Capability,
                makeDirectory: @escaping @Sendable (String) async throws -> Void,
                readFile: @escaping @Sendable (String) async throws -> Data?,
                writeFile: @escaping @Sendable (String, Data, Int) async throws -> Void,
                commitFiles: @escaping @Sendable (String, String, String, String) async throws -> Void,
                removeFile: @escaping @Sendable (String) async throws -> Void,
                isLive: (@Sendable () async throws -> Bool)? = nil) {
        self.machineID = machineID
        self.isLive = isLive ?? { true }
        self.capability = capability
        self.makeDirectory = makeDirectory
        self.readFile = readFile
        self.writeFile = writeFile
        self.commitFiles = commitFiles
        self.removeFile = removeFile
    }

    private static let statusCommand = [
        "set -eu",
        #"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#,
        #"as_u() { if [ "$(id -un)" = "$u" ]; then "$@"; else root runuser -u "$u" -- "$@"; fi; }"#,
        #"u=cmux; id -u "$u" >/dev/null 2>&1 || u=root"#,
        #"h=$(getent passwd "$u" | cut -d: -f6)"#,
        #"b="$h/.cmux/bin/cmux-tui""#,
        #"[ -x "$b" ] || { echo "cmux: this machine has no cmux-tui" >&2; exit 82; }"#,
        #"as_u env HOME="$h" "$b" acp --json status"#,
    ].joined(separator: "; ")

    static func supportsExternalAccess(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilities = object["capabilities"] as? [String] else { return false }
        return capabilities.contains("codex-external-access-v1")
    }

    /// The default probe is deliberately read-only: the running bridge reports
    /// its capability and the guest marker proves that this is an owner VM.
    nonisolated public init(api: CloudAPIClient, machineID: String, scope: CloudCodexBrokerScope) {
        let api = api.pinningTeam(scope.teamID)
        self.init(machineID: machineID, capability: {
            let marker = try await api.readFile(machineID, path: "/etc/cmux/vm-kind")
            let owner = String(decoding: marker.data ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "owner"
            let sharedTeamDirectory: Bool
            do {
                _ = try await api.statFile(machineID, path: "/srv/team")
                sharedTeamDirectory = true
            } catch let error as CloudAPIError {
                switch error {
                case .http(let status, let code, _, _, _)
                    where status == 404 && code == "vm_file_not_found":
                    break
                default:
                    throw error
                }
                sharedTeamDirectory = false
            }
            guard owner, !sharedTeamDirectory else { return Capability(ownerVM: false, protocolVersion: 0, codexExternalAccessToken: false) }
            let result = try await api.exec(machineID, command: Self.statusCommand, timeoutMs: 8_000)
            guard result.exitCode == 0, Self.supportsExternalAccess(result.stdout) else {
                return Capability(ownerVM: true, protocolVersion: 0, codexExternalAccessToken: false)
            }
            return Capability(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { path in
            try await api.makeDirectory(machineID, path: path)
        }, readFile: { path in
            do { return try await api.readFile(machineID, path: path).data }
            catch let error as CloudAPIError {
                guard case .http(let status, let code, _, _, _) = error,
                      status == 404, code == "vm_file_not_found" else { throw error }
                return nil
            }
        }, writeFile: { path, data, mode in
            try await api.writeFile(machineID, path: path, data: data, mode: mode)
        }, commitFiles: { stageAccess, finalAccess, stageMode, finalMode in
            let script = "set -eu; for p in \(stageAccess) \(stageMode); do test -f $p; test ! -L $p; test $(stat -c %a $p) = 600; case $(stat -c %u $p) in 0|$(id -u cmux)) ;; *) exit 83 ;; esac; chown cmux:cmux $p; done; mv -f \(stageMode) \(finalMode); mv -f \(stageAccess) \(finalAccess)"
            let result = try await api.exec(machineID, command: script, timeoutMs: 8_000)
            guard result.exitCode == 0 else { throw CloudCodexBrokerError.remoteDeliveryFailed }
        }, removeFile: { path in
            do { try await api.removeFile(machineID, path: path) }
            catch let error as CloudAPIError {
                guard case .http(let status, let code, _, _, _) = error,
                      status == 404, code == "vm_file_not_found" else { throw error }
            }
        }, isLive: {
            (try await api.machine(machineID)).status.isLive
        })
    }
}

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
    private var cached: CloudCodexAccessGrant?
    private var previousModeByMachine: [String: Data?] = [:]
    private var loadedPreviousMode: Set<String> = []
    private var targets: [String: CloudCodexBrokerTarget] = [:]
    private var targetGenerations: [String: Int] = [:]
    private var pendingRevocations: Set<String> = []
    private var targetLocks: Set<String> = []
    private var targetWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshCycle = 0
    private var refreshInFlight: Task<CloudCodexAccessGrant, any Error>?

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
        let response = try await request(method: "login")
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
        let generation = targetGenerations[target.machineID, default: 0]
        try await validate(target: target, confirmed: confirmed)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard targetGenerations[target.machineID, default: 0] == generation else { throw CloudCodexBrokerError.cancelled }
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
    }

    /// Reuses a cached short-lived access grant when possible; otherwise asks
    /// the local holder to refresh and writes only the new access token.
    public func transfer(target: CloudCodexBrokerTarget, confirmed: Bool,
                         forceRefresh: Bool = false) async throws -> CloudCodexAccessGrant {
        let generation = targetGenerations[target.machineID, default: 0]
        try await validate(target: target, confirmed: confirmed)
        try await ensureScope()
        guard targetGenerations[target.machineID, default: 0] == generation else { throw CloudCodexBrokerError.cancelled }
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
        await lockTarget(target.machineID)
        defer { unlockTarget(target.machineID) }
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
        try await target.removeFile(Self.accessPath)
        try await target.removeFile(Self.modePath)
        if let previous = previousModeByMachine[target.machineID] ?? nil {
            try await target.writeFile(Self.modePath, previous, 0o600)
        }
        previousModeByMachine.removeValue(forKey: target.machineID)
        loadedPreviousMode.remove(target.machineID)
        pendingRevocations.remove(target.machineID)
        if targets.isEmpty {
            cached = nil
            refreshTask?.cancel()
            refreshTask = nil
            if signOut { _ = try? await request(method: "logout") }
        }
    }

    private func validate(target: CloudCodexBrokerTarget, confirmed: Bool) async throws {
        guard confirmed else { throw CloudCodexBrokerError.consentRequired }
        guard await currentScope() == scope else { throw CloudCodexBrokerError.scopeChanged }
        guard try await target.isLive() else { throw CloudCodexBrokerError.targetOffline }
        let capability = try await target.capability()
        guard capability.ownerVM else { throw CloudCodexBrokerError.sharedMachine }
        guard capability.protocolVersion == Self.protocolVersion, capability.codexExternalAccessToken else {
            throw CloudCodexBrokerError.unsupportedMachine
        }
    }

    private func request(method: String, force: Bool? = nil, previousAccountID: String? = nil) async throws -> BrokerResult {
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
        guard targetGenerations[target.machineID, default: 0] == generation else { throw CloudCodexBrokerError.cancelled }
        let object: [String: Any] = [
            "schema": 1,
            "bridge": "codex-external-access-v1",
            "accessToken": grant.accessToken,
            "chatgptAccountId": grant.chatgptAccountID,
            "expiresAt": Int64(grant.expiresAt.timeIntervalSince1970),
        ]
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw CloudCodexBrokerError.invalidReply
        }
        let suffix = UUID().uuidString.lowercased()
        let stageAccess = "/home/cmux/.config/cmux/codex-broker/.access-\(suffix).json"
        let stageMode = "/home/cmux/.config/cmux/agent-auth/.codex-\(suffix)"
        var commitAttempted = false
        var stagingAttempted = false
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
            stagingAttempted = true
            try await target.writeFile(stageAccess, data, 0o600)
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
            try await target.writeFile(stageMode, Data("own\n".utf8), 0o600)
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
            commitAttempted = true
            try await target.commitFiles(stageAccess, Self.accessPath, stageMode, Self.modePath)
            try await ensureScope()
            try? await target.removeFile(stageAccess)
            try? await target.removeFile(stageMode)
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
        } catch {
            if commitAttempted || Task.isCancelled || error as? CloudCodexBrokerError == .scopeChanged {
                targets.removeValue(forKey: target.machineID)
                targetGenerations[target.machineID, default: 0] += 1
                pendingRevocations.insert(target.machineID)
            }
            let previous = previousModeByMachine[target.machineID] ?? nil
            // Cleanup must complete even when the initiating task was cancelled.
            let cleanup = Task {
                if stagingAttempted {
                    try? await target.removeFile(stageAccess)
                    try? await target.removeFile(stageMode)
                }
                if commitAttempted {
                    try await target.removeFile(Self.accessPath)
                    try await target.removeFile(Self.modePath)
                    if let previous { try await target.writeFile(Self.modePath, previous, 0o600) }
                }
            }
            do { try await cleanup.value }
            catch { throw CloudCodexBrokerError.remoteDeliveryFailed }
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
        guard await currentScope() == scope else { throw CloudCodexBrokerError.scopeChanged }
        guard !Task.isCancelled else { throw CloudCodexBrokerError.cancelled }
    }

    func registeredMachineIDs() -> Set<String> { Set(targets.keys) }

    private func targetList() -> [CloudCodexBrokerTarget] { targets.values.sorted { $0.machineID < $1.machineID } }

    private func scheduleRefresh(grant: CloudCodexAccessGrant) {
        refreshTask?.cancel()
        refreshCycle += 1
        let cycle = refreshCycle
        let wait = max(1, grant.expiresAt.timeIntervalSinceNow - 120)
        let expectedScope = scope
        refreshTask = Task { [weak self] in
            do {
                // wakeup-allow: one renewal wakeup before the short-lived grant expires
                try await Task.sleep(for: .seconds(wait))
                guard let self, await self.currentScope() == expectedScope else { return }
                let refreshed = try await self.refreshAccess(schedule: false)
                let targets = await self.targetList()
                for target in targets {
                    do { try await self.deliver(refreshed, target: target) }
                    catch CloudCodexBrokerError.scopeChanged { throw CloudCodexBrokerError.scopeChanged }
                    catch { continue }
                }
                await self.rescheduleRefresh(after: refreshed, cycle: cycle)
            } catch { /* cancellation, logout, or a stopped VM ends renewal */ }
        }
    }

    private func rescheduleRefresh(after grant: CloudCodexAccessGrant, cycle: Int) {
        guard cycle == refreshCycle, !Task.isCancelled, !targets.isEmpty else { return }
        // This method runs on the renewal task itself; clear its handle before
        // installing the next one so scheduleRefresh cannot cancel this task.
        refreshTask = nil
        scheduleRefresh(grant: grant)
    }

}

/// Reuses one holder actor for each signed-in user/team scope. A VM target is
/// passed to transfer per call, while the rotating local refresh cache remains one per scope.
public actor CloudCodexBrokerRegistry {
    private var brokers: [CloudCodexBrokerScope: CloudCodexBroker] = [:]

    public init() {}

    public func broker(for scope: CloudCodexBrokerScope,
                       currentScope: @escaping @Sendable () async -> CloudCodexBrokerScope?,
                       executable: URL,
                       executablePrefix: [String] = [],
                       codexExecutable: URL,
                       home: URL) -> CloudCodexBroker {
        if let broker = brokers[scope] { return broker }
        let broker = CloudCodexBroker(scope: scope, currentScope: currentScope, executable: executable,
                                      executablePrefix: executablePrefix, codexExecutable: codexExecutable, home: home)
        brokers[scope] = broker
        return broker
    }

    public func remove(scope: CloudCodexBrokerScope) {
        brokers.removeValue(forKey: scope)
    }
}

