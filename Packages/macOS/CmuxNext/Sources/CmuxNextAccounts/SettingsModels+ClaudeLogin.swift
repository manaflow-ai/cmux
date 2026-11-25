public import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
public import Foundation

extension SettingsModels {
    /// A Settings sign-in bound to a specific Cloud machine and to the browser that can reach its callback.
    public enum CloudClaudeLogin {
        case connectable
        case sharedMachine
        case ready(CloudClaudeMachine)
    }

    /// The Cloud machine's owner connection. The app supplies it from the current Cloud account.
    public struct CloudClaudeMachine {
        public let id: String
        let name: String?
        let request: @MainActor (String, [String: String]) async throws -> Data
        /// True while this approval remains the current sign-in attempt.
        public typealias CallbackScope = @MainActor @Sendable () -> Bool
        /// Opens the isolated approval browser while the attempt is still active.
        public typealias CallbackOpener = @MainActor (URL, String, @escaping CallbackScope) async -> Bool
        let openCallback: CallbackOpener

        /// Bind requests and browser approval to the same machine.
        public init(id: String, name: String? = nil, request: @escaping @MainActor (String, [String: String]) async throws -> Data,
                    openCallback: @escaping CallbackOpener) {
            self.id = id
            self.name = name
            self.request = request
            self.openCallback = openCallback
        }
    }

    enum ClaudeLoginTarget: Hashable {
        case mac, cloud
    }

    struct ClaudeLoginState: Equatable {
        var phase = "idle"
        var error: String?
        var apiKey = false
        var signedIn: Bool?
        var machine: String?
        var machineName: String?
        var completion: String?

        var pageState: JSONValue {
            ["phase": .string(phase), "error": error.map(JSONValue.string) ?? .null, "apiKey": .bool(apiKey),
             "signedIn": signedIn.map(JSONValue.bool) ?? .null,
             "machineName": machineName.map(JSONValue.string) ?? .null,
             "machine": machine.map(JSONValue.string) ?? .null,
             "completion": completion.map(JSONValue.string) ?? .null]
        }
    }

    struct ClaudeLoginAttempt {
        let id: String
        let machine: CloudClaudeMachine?
    }

    /// Cancels the Cloud flow if the user or team changes. A nil account also covers sign-out in progress.
    public func observeCloudClaudeAccount(_ account: @escaping @MainActor @Sendable () -> [String?]?) {
        cloudClaudeAccount = account
        cloudClaudeAccountWatch?.cancel()
        // task-owner: the Settings model observes the Cloud account until deinit.
        cloudClaudeAccountWatch = Task { [weak self] in
            for await scope in ObservationStream(account) {
                self?.invalidateCloudClaudeLogin(unless: scope)
            }
        }
    }

    private func invalidateCloudClaudeLogin(unless account: [String?]?) {
        guard cloudClaudeStateAccount != account else { return }
        claudeLoginTasks[.cloud]?.cancel()
        claudeLoginTimers.removeValue(forKey: .cloud)?.cancel()
        if let attempt = claudeLoginAttempts.removeValue(forKey: .cloud) {
            dismissSignInPage?("claude:\(attempt.id)")
        }
        claudeLogins[.cloud] = nil
        cloudClaudeStateAccount = account
    }

    func claudeLoginState(_ target: ClaudeLoginTarget) -> ClaudeLoginState {
        if target == .mac { return claudeLogins[target] ?? .init() }
        let state = currentCloudClaudeState
        if let state, ["preparing", "approving", "code", "cancelling"].contains(state.phase) {
            return state
        }
        switch cloudClaudeLogin?(state?.machine) ?? .connectable {
        case .sharedMachine: return .init(phase: "disabled", error: "shared_machine")
        case .connectable:
            return state?.machine == nil ? state ?? .init() : .init()
        case .ready(let machine):
            guard let state, state.machine == machine.id || (state.machine == nil && state.phase == "failed") else {
                return .init(machine: machine.id, machineName: machine.name)
            }
            return state
        }
    }

    private var currentCloudClaudeState: ClaudeLoginState? {
        cloudClaudeStateAccount == cloudClaudeAccount?() ? claudeLogins[.cloud] : nil
    }

    private func claudeMachine(_ target: ClaudeLoginTarget, preferred: String? = nil) throws -> CloudClaudeMachine? {
        guard target == .cloud else { return nil }
        let id = preferred ?? currentCloudClaudeState?.machine
        guard case .ready(let machine) = cloudClaudeLogin?(id), id == nil || machine.id == id else {
            throw PageError.unavailable("Claude Code is unavailable on this Cloud machine")
        }
        return machine
    }

    func checkClaudeLogin(_ target: ClaudeLoginTarget, machine preferred: String?) async {
        let phase = target == .cloud && preferred != nil && currentCloudClaudeState?.machine != preferred
            ? "idle" : claudeLoginState(target).phase
        guard claudeLoginTasks[target] == nil, claudeLoginAttempts[target] == nil,
              phase != "disabled", target == .mac || phase != "failed" else { return }
        let account = cloudClaudeAccount?()
        let machine = try? claudeMachine(target, preferred: preferred)
        guard target == .mac || machine != nil else { return }
        let previous = claudeLogins[target]
        let stillChecking = {
            self.claudeLoginTasks[target] == nil && self.claudeLoginAttempts[target] == nil &&
                (target == .mac || (self.cloudClaudeAccount?() == account &&
                    self.claudeLogins[target] == previous &&
                    (try? self.claudeMachine(target, preferred: preferred))?.id == machine?.id))
        }
        do {
            let reply = try await claudeCall(.claudeLoginStatus, "status", ["agent": "claude"], machine: machine)
            guard stillChecking() else { return }
            setClaudeLogin(target, machine, reply["signedIn"]?.boolValue == true ? "connected" : "idle",
                           apiKey: reply["apiKey"]?.boolValue == true, signedIn: reply["signedIn"]?.boolValue == true)
        } catch {
            guard stillChecking(), !(error is CancellationError) else { return }
            setClaudeFailure(target, machine, error)
        }
    }

    func beginClaudeLogin(_ target: ClaudeLoginTarget, replacing: String?, machine requestedMachine: String?) throws {
        guard claudeLoginTasks[target] == nil, claudeLoginAttempts[target] == nil else { return }
        let preferred = requestedMachine ?? (replacing == "claude-cloud-login" ? currentCloudClaudeState?.machine : nil)
        let prepare = target == .cloud ? prepareCloudClaudeLogin : nil
        let initial = prepare == nil ? try claudeMachine(target, preferred: preferred) : nil
        let account = cloudClaudeAccount?()
        if target == .cloud {
            guard cloudClaudeAccount == nil || account != nil else { return }
            if (preferred == nil || currentCloudClaudeState?.machine == preferred),
               claudeLoginState(target).phase == "disabled" { return }
        }
        setClaudeLogin(target, initial, prepare == nil ? "approving" : "preparing")
        // task-owner: the Settings model owns the preparation and sign-in until they settle.
        claudeLoginTasks[target] = Task { [weak self] in
            guard let self else { return }
            defer { claudeLoginTasks[target] = nil }
            var machine = initial
            do {
                if let prepare {
                    try checkClaudeAccount(target, account)
                    machine = try await prepare(preferred)
                    try checkClaudeAccount(target, account)
                    guard let machine else { return setClaudeLogin(target, nil, "idle") }
                    guard preferred == nil || preferred == machine.id else { throw SettingsCloudClaudeLogin.startFailure }
                    setClaudeLogin(target, machine, "approving")
                }
                var fields = ["agent": "claude"]
                if replacing == "claude-cloud-login" { fields["reauthenticate"] = "true" }
                let started = try await claudeCall(.claudeLoginStart, "start", fields, machine: machine)
                try checkClaudeAccount(target, account)
                if started["signedIn"]?.boolValue == true {
                    if replacing == "claude-cloud-login" { throw PageError(code: "cmux.models.unsupported", message: "Cloud machine does not support reauthentication") }
                    guard claudeLogins[target]?.phase != "cancelling" else {
                        return setClaudeLogin(target, machine, "idle")
                    }
                    setClaudeLogin(target, machine, "approving", apiKey: started["apiKey"]?.boolValue)
                    return try await completeClaudeLogin(target, machine)
                }
                if claudeLogins[target]?.phase != "cancelling" {
                    setClaudeLogin(target, machine, "approving", apiKey: started["apiKey"]?.boolValue)
                }
                guard let id = started["loginId"]?.stringValue else { throw PageError.unavailable("Claude sign-in could not start") }
                claudeLoginAttempts[target] = .init(id: id, machine: machine)
                if claudeLogins[target]?.phase == "cancelling" {
                    return await settleClaudeCancellation(target)
                }
                let browserOwner = "claude:\(id)"
                if let automatic = started["autoUrl"]?.stringValue.flatMap(URL.init(string:)),
                   let port = AgentPaneSignInPage.callbackPort(automatic),
                   started["callbackPort"]?.intValue == Int(port) {
                    let current: CloudClaudeMachine.CallbackScope = { [weak self] in
                        self?.claudeLoginAttempts[target]?.id == id && self?.claudeLogins[target]?.phase == "approving"
                    }
                    let openCallback = machine?.openCallback ?? presentClaudeCallback
                    let opened = await openCallback?(automatic, browserOwner, current) == true
                    try checkClaudeAccount(target, account)
                    guard claudeLoginAttempts[target]?.id == id, claudeLogins[target]?.phase == "approving" else { return }
                    if opened { return try await finishClaudeAttempt(target, code: nil) }
                }
                guard let manual = started["url"]?.stringValue.flatMap(URL.init(string:)),
                      AgentPaneSignInPage().allowed(manual, forClaude: true),
                      AgentPaneSignInPage.callbackPort(manual) == nil else {
                    throw PageError.unavailable("Claude sign-in link is unavailable")
                }
                try await openSignIn(manual, owner: browserOwner)
                try checkClaudeAccount(target, account)
                guard claudeLoginAttempts[target]?.id == id, claudeLogins[target]?.phase == "approving" else { return }
                setClaudeLogin(target, machine, "code")
                let remaining = started["expiresAtMs"]?.intValue.map { Double($0) / 1000 - Date.now.timeIntervalSince1970 }
                let timer = DemandTimer(owner: "settings.models.claudeLogin")
                claudeLoginTimers[target] = timer
                timer.schedule(after: .seconds(max(0, min(900, remaining ?? 900)))) { @MainActor [weak self] in
                    guard let self, claudeLoginAttempts[target]?.id == id,
                          target == .mac || cloudClaudeAccount?() == account else { return }
                    dismissSignInPage?(browserOwner)
                    claudeLoginAttempts[target] = nil
                    claudeLoginTimers[target] = nil
                    setClaudeLogin(target, machine, "failed", error: "expired")
                }
            } catch {
                guard target == .mac || cloudClaudeAccount?() == account,
                      let state = claudeLogins[target], state.phase != "idle" else { return }
                let cancelling = state.phase == "cancelling" || error is CancellationError
                await settleClaudeCancellation(target)
                if !cancelling, target == .mac || cloudClaudeAccount?() == account { setClaudeFailure(target, machine, error) }
            }
        }
    }

    func finishClaudeLogin(_ target: ClaudeLoginTarget, code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard claudeLoginTasks[target] == nil, let attempt = claudeLoginAttempts[target],
              claudeLoginState(target).phase == "code", Self.isOneWord(code), code.utf8.count <= 4096 else { return }
        let account = cloudClaudeAccount?()
        guard target == .mac || cloudClaudeStateAccount == account else { return }
        claudeLoginTimers.removeValue(forKey: target)?.cancel()
        setClaudeLogin(target, attempt.machine, "approving")
        // task-owner: the Settings model owns this fallback completion until it settles.
        claudeLoginTasks[target] = Task { [weak self] in
            guard let self else { return }
            defer { claudeLoginTasks[target] = nil }
            do {
                try await finishClaudeAttempt(target, code: code)
            } catch {
                guard target == .mac || cloudClaudeAccount?() == account else { return }
                let cancelling = claudeLogins[target]?.phase == "cancelling"
                await settleClaudeCancellation(target)
                if !cancelling, !(error is CancellationError), target == .mac || cloudClaudeAccount?() == account {
                    setClaudeFailure(target, attempt.machine, error)
                }
            }
        }
    }

    func cancelClaudeLogin(_ target: ClaudeLoginTarget) async {
        guard let state = claudeLogins[target], ["preparing", "approving", "code"].contains(state.phase) else { return }
        claudeLogins[target]?.phase = "cancelling"
        if state.phase == "preparing" { claudeLoginTasks[target]?.cancel() }
        if claudeLoginAttempts[target] != nil { await settleClaudeCancellation(target) }
    }

    func signOutClaude(_ target: ClaudeLoginTarget, machine requested: String?) async throws {
        guard claudeLoginTasks[target] == nil, claudeLoginAttempts[target] == nil else { return }
        let id = requested ?? currentCloudClaudeState?.machine
        if target == .cloud, id == nil { throw PageError.invalidParams("Cloud Claude sign-out needs a machine") }
        let machine = try claudeMachine(target, preferred: id)
        let account = cloudClaudeAccount?()
        do {
            _ = try await claudeCall(.claudeLoginLogout, "logout", ["agent": "claude"], machine: machine)
            try checkClaudeAccount(target, account)
            if target == .mac { await refresh() }
            setClaudeLogin(target, machine, "idle", signedIn: false)
        } catch {
            guard !(error is CancellationError), target == .mac || cloudClaudeAccount?() == account else { return }
            setClaudeFailure(target, machine, error)
        }
    }

    private func finishClaudeAttempt(_ target: ClaudeLoginTarget, code: String?) async throws {
        guard let attempt = claudeLoginAttempts[target] else { return }
        let account = cloudClaudeAccount?()
        var fields = ["loginId": attempt.id]
        if let code { fields["code"] = code }
        let reply = try await claudeCall(.claudeLoginFinish, "finish", fields, machine: attempt.machine)
        try checkClaudeAccount(target, account)
        guard claudeLoginAttempts[target]?.id == attempt.id else { return }
        guard reply["signedIn"]?.boolValue == true else { throw PageError.unavailable("Claude Code did not sign in") }
        claudeLoginAttempts[target] = nil
        dismissSignInPage?("claude:\(attempt.id)")
        try await completeClaudeLogin(target, attempt.machine)
    }

    private func completeClaudeLogin(_ target: ClaudeLoginTarget, _ machine: CloudClaudeMachine?) async throws {
        let account = cloudClaudeStateAccount
        try checkClaudeAccount(target, account)
        await refresh()
        try checkClaudeAccount(target, account)
        setClaudeLogin(target, machine, "connected", signedIn: true, completion: UUID().uuidString)
        if let machine { onCloudClaudeSignIn?(machine.id) }
    }

    private func checkClaudeAccount(_ target: ClaudeLoginTarget, _ account: [String?]?) throws {
        guard target == .cloud else { return }
        try Task.checkCancellation()
        guard cloudClaudeAccount?() == account else { throw CancellationError() }
    }

    private func settleClaudeCancellation(_ target: ClaudeLoginTarget) async {
        let account = cloudClaudeStateAccount
        if let attempt = claudeLoginAttempts.removeValue(forKey: target) {
            dismissSignInPage?("claude:\(attempt.id)")
            _ = try? await claudeCall(.claudeLoginCancel, "cancel", ["loginId": attempt.id], machine: attempt.machine)
        }
        guard target == .mac || cloudClaudeAccount?() == account else { return }
        claudeLoginTimers.removeValue(forKey: target)?.cancel()
        claudeLogins[target]?.phase = "idle"
    }

    private func claudeCall(_ method: AcpmuxHarnessMethod, _ op: String, _ fields: [String: String],
                            machine: CloudClaudeMachine?) async throws -> JSONValue {
        let data: Data
        if let machine {
            data = try await machine.request(op, fields)
        } else {
            var params: [String: any Sendable] = fields
            if method == .claudeLoginStart { params["reuseExisting"] = true }
            data = try await daemon(try requireDaemonEnvironment(), method, params)
        }
        let reply = try JSONValue.parse(data)
        if let reason = reply["refused"]?["reason"]?.stringValue {
            throw PageError(code: "cmux.models.\(reason)", message: "Claude sign-in was refused")
        }
        return reply
    }

    private func setClaudeFailure(_ target: ClaudeLoginTarget, _ machine: CloudClaudeMachine?, _ error: any Error) {
        let refusal = Self.daemonRefusal(error)
        let reason = refusal == "unknown_login" ? "expired" : refusal ?? "failed"
        let disabled = ["cli_missing", "update_claude", "shared_machine", "unsupported"].contains(reason)
        setClaudeLogin(target, machine, disabled ? "disabled" : "failed", error: reason)
    }

    private func setClaudeLogin(_ target: ClaudeLoginTarget, _ machine: CloudClaudeMachine?, _ phase: String,
                                error: String? = nil, apiKey: Bool? = nil, signedIn: Bool? = nil, completion: String? = nil) {
        let account = cloudClaudeAccount?()
        let previous = claudeLogins[target].flatMap {
            $0.machine == machine?.id && (target == .mac || cloudClaudeStateAccount == account) ? $0 : nil
        }
        if target == .cloud { cloudClaudeStateAccount = account }
        claudeLogins[target] = .init(phase: phase, error: error, apiKey: apiKey ?? previous?.apiKey ?? false,
                                    signedIn: signedIn ?? previous?.signedIn, machine: machine?.id, machineName: machine?.name,
                                    completion: completion ?? previous?.completion)
    }
}
