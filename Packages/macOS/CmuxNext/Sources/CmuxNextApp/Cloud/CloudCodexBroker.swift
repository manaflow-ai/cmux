import CmuxNextCloud
import CmuxNextDaemon
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
                isLive: @escaping @Sendable () async throws -> Bool = { true }) {
        self.machineID = machineID
        self.isLive = isLive
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
            guard result.exitCode == 0,
                  let line = result.stdout.split(separator: "\n").last,
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let capabilities = object["capabilities"] as? [String],
                  capabilities.contains("codex-external-access-v1") else {
                return Capability(ownerVM: true, protocolVersion: 0, codexExternalAccessToken: false)
            }
            return Capability(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { path in
            try await api.makeDirectory(machineID, path: path)
        }, readFile: { path in
            do { return try await api.readFile(machineID, path: path).data }
            catch { return nil }
        }, writeFile: { path, data, mode in
            try await api.writeFile(machineID, path: path, data: data, mode: mode)
        }, commitFiles: { stageAccess, finalAccess, stageMode, finalMode in
            let script = "set -eu; test -f \(stageAccess); test -f \(stageMode); test $(stat -c %U \(stageAccess)) = cmux; test $(stat -c %U \(stageMode)) = cmux; install -o cmux -g cmux -m 600 \(stageAccess) \(finalAccess).tmp; install -o cmux -g cmux -m 600 \(stageMode) \(finalMode).tmp; mv -f \(finalAccess).tmp \(finalAccess); mv -f \(finalMode).tmp \(finalMode)"
            let result = try await api.exec(machineID, command: script, timeoutMs: 8_000)
            guard result.exitCode == 0 else { throw CloudCodexBrokerError.remoteDeliveryFailed }
        }, removeFile: { path in
            try await api.removeFile(machineID, path: path)
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
    private var refreshTask: Task<Void, Never>?
    private var refreshInFlight: Task<CloudCodexAccessGrant, Error>?

    nonisolated public init(scope: CloudCodexBrokerScope,
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
        try await validate(target: target, confirmed: confirmed)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
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
        try await validate(target: target, confirmed: confirmed)
        targets[target.machineID] = target
        targetGenerations[target.machineID, default: 0] += 1
        if !forceRefresh, let cached, cached.expiresAt > Date().addingTimeInterval(120) {
            try await deliver(cached, target: target)
            return cached
        }
        let grant = try await refreshAccess(schedule: true)
        try await deliver(grant, target: target)
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
        try await validate(target: target, confirmed: true, requireLive: false)
        targets.removeValue(forKey: target.machineID)
        targetGenerations[target.machineID, default: 0] += 1
        // A paused VM must not be woken merely to revoke. Its bridge will reject
        // the old file on its next start; a live VM is erased immediately below.
        guard (try? await target.isLive()) == true else {
            loadedPreviousMode.remove(target.machineID)
            previousModeByMachine.removeValue(forKey: target.machineID)
            if targets.isEmpty {
                cached = nil
                refreshTask?.cancel()
                refreshTask = nil
                if signOut { _ = try? await request(method: "logout") }
            }
            return
        }
        try? await target.removeFile(Self.accessPath)
        try? await target.removeFile(Self.modePath)
        if let previous = previousModeByMachine.removeValue(forKey: target.machineID) ?? nil {
            try await target.writeFile(Self.modePath, previous, 0o600)
        }
        loadedPreviousMode.remove(target.machineID)
        if targets.isEmpty {
            cached = nil
            refreshTask?.cancel()
            refreshTask = nil
            if signOut { _ = try? await request(method: "logout") }
        }
    }

    private func validate(target: CloudCodexBrokerTarget, confirmed: Bool, requireLive: Bool = true) async throws {
        guard confirmed else { throw CloudCodexBrokerError.consentRequired }
        guard await currentScope() == scope else { throw CloudCodexBrokerError.scopeChanged }
        guard requireLive else { return }
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
            throw CloudCodexBrokerError.cancelled
        } catch CodexBrokerSession.Error.notAuthenticated {
            throw CloudCodexBrokerError.notAuthenticated
        } catch CodexBrokerSession.Error.invalidReply {
            throw CloudCodexBrokerError.invalidReply
        } catch CodexBrokerSession.Error.accountChanged {
            throw CloudCodexBrokerError.accountChanged
        } catch {
            throw CloudCodexBrokerError.brokerUnavailable
        }
    }

    private func deliver(_ grant: CloudCodexAccessGrant, target: CloudCodexBrokerTarget) async throws {
        guard targets[target.machineID] != nil else { throw CloudCodexBrokerError.cancelled }
        let generation = targetGenerations[target.machineID, default: 0]
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
        do {
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
            try await target.writeFile(stageAccess, data, 0o600)
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
            try await target.writeFile(stageMode, Data("own\n".utf8), 0o600)
            try await ensureScope()
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
            try await target.commitFiles(stageAccess, Self.accessPath, stageMode, Self.modePath)
            guard targets[target.machineID] != nil, targetGenerations[target.machineID] == generation else { throw CloudCodexBrokerError.cancelled }
        } catch let error as CloudCodexBrokerError {
            try? await target.removeFile(stageAccess)
            try? await target.removeFile(stageMode)
            throw error
        } catch {
            try? await target.removeFile(stageAccess)
            try? await target.removeFile(stageMode)
            throw CloudCodexBrokerError.remoteDeliveryFailed
        }
    }

    private func ensureScope() async throws {
        guard await currentScope() == scope else { throw CloudCodexBrokerError.scopeChanged }
    }

    private func targetList() -> [CloudCodexBrokerTarget] { Array(targets.values) }

    private func scheduleRefresh(grant: CloudCodexAccessGrant) {
        refreshTask?.cancel()
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
                    catch CloudCodexBrokerError.targetOffline { continue }
                    catch CloudCodexBrokerError.remoteDeliveryFailed { continue }
                }
                await self.rescheduleRefresh(after: refreshed)
            } catch { /* cancellation, logout, or a stopped VM ends renewal */ }
        }
    }

    private func rescheduleRefresh(after grant: CloudCodexAccessGrant) {
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

    nonisolated public init() {}

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

nonisolated private struct BrokerRequest: Encodable, Sendable {
    let id: Int
    let method: String
    let force: Bool?
    let previousAccountId: String?
}

nonisolated private struct BrokerResult: Decodable, Sendable {
    let accessToken: String?
    let chatgptAccountID: String?
    let expiresAt: Double?
    let verificationURL: String?
    let userCode: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case chatgptAccountID = "chatgptAccountId"
        case expiresAt
        case verificationURL = "verificationUrl"
        case userCode
    }
}

nonisolated private struct BrokerReply: Decodable, Sendable {
    let id: Int
    let result: BrokerResult?
    let error: String?
}

private actor CodexBrokerSession {
    enum Error: Swift.Error { case invalidReply, accountChanged, notAuthenticated, timedOut }

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    // task-owner: this reader is cancelled with the private broker process.
    private var readTask: Task<Void, Never>?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<BrokerResult, Swift.Error>] = [:]

    init(executable: URL, executablePrefix: [String], codexExecutable: URL, home: URL) throws {
        try FileManager.checked.createDirectory(at: home, withIntermediateDirectories: true)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = executablePrefix + ["codex-auth-broker", "--home", home.path, "--codex", codexExecutable.path]
        var environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path]
        if let user = ProcessInfo.processInfo.environment["USER"] { environment["USER"] = user }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.readTask = Task { [weak self, output = outputPipe.fileHandleForReading] in
            do {
                for try await line in output.bytes.lines {
                    await self?.consume(Data((line + "\n").utf8))
                }
            } catch {
                await self?.terminatePending()
            }
        }
        process.terminationHandler = { [weak self] _ in
            // task-owner: termination handler reports EOF to the stored reader task.
            Task { await self?.terminatePending() }
        }
    }

    deinit {
        readTask?.cancel()
        try? input.close()
        try? output.close()
        if process.isRunning { process.terminate() }
    }

    func request(method: String, force: Bool? = nil, previousAccountID: String? = nil) async throws -> BrokerResult {
        nextID += 1
        let id = nextID
        let object = BrokerRequest(id: id, method: method, force: force, previousAccountId: previousAccountID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(object) else { throw Error.invalidReply }
        var line = data
        line.append(0x0A)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try input.write(contentsOf: line)
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // task-owner: cancellation is sent to the session actor and does not outlive its private child.
            Task.detached(priority: .utility) { await self.cancelPending() }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 64 * 1024 else {
            terminatePending()
            if process.isRunning { process.terminate() }
            buffer.removeAll(keepingCapacity: false)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let reply = try? JSONDecoder().decode(BrokerReply.self, from: line),
                  let continuation = pending.removeValue(forKey: reply.id) else { continue }
            if let error = reply.error {
                if error == "codex_auth_account_changed" { continuation.resume(throwing: Error.accountChanged) }
                else if error == "codex_auth_unavailable" { continuation.resume(throwing: Error.notAuthenticated) }
                else { continuation.resume(throwing: Error.invalidReply) }
            } else if let result = reply.result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: Error.invalidReply)
            }
        }
    }

    private func terminatePending() {
        guard !pending.isEmpty else { return }
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: Error.invalidReply) }
    }

    private func cancelPending() {
        guard !pending.isEmpty else { return }
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
        if process.isRunning { process.terminate() }
    }
}
