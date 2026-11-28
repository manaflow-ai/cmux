public import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
public import Foundation
import Observation

extension SettingsModels {
    /// The app's single Cloud approval slot, shared by its Settings pages.
    @MainActor @Observable
    public final class CloudClaudeApproval {
        private var owner: UUID?

        /// Creates the approval slot for one app instance.
        public init() {}

        func isBusy(for owner: UUID) -> Bool { self.owner != nil && self.owner != owner }

        func acquire(_ owner: UUID) -> Bool {
            guard self.owner == nil else { return false }
            self.owner = owner
            return true
        }

        func release(_ owner: UUID) {
            if self.owner == owner { self.owner = nil }
        }
    }

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
        let environment: String?
        let request: @MainActor (String, [String: String]) async throws -> Data
        /// True while this approval remains the current sign-in attempt.
        public typealias CallbackScope = @MainActor @Sendable () -> Bool
        /// Opens the isolated approval browser while the attempt is still active.
        public typealias CallbackOpener = @MainActor (URL, String, @escaping CallbackScope) async -> Bool
        let openCallback: CallbackOpener

        /// Bind requests and browser approval to the same machine.
        public init(id: String, name: String? = nil, environment: String? = nil, request: @escaping @MainActor (String, [String: String]) async throws -> Data,
                    openCallback: @escaping CallbackOpener) {
            self.id = id
            self.name = name
            self.environment = environment
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
        var environment: String?
        var recoverySession: String?
        var completion: String?
        var waitsForGuestUpdate = false

        var blocksConnect: Bool { phase == "disabled" && error != "update_claude" && error != "cli_missing" }

        var pageState: JSONValue {
            ["phase": .string(phase), "error": error.map(JSONValue.string) ?? .null, "apiKey": .bool(apiKey),
             "signedIn": signedIn.map(JSONValue.bool) ?? .null,
             "machineName": machineName.map(JSONValue.string) ?? .null,
             "machine": machine.map(JSONValue.string) ?? .null,
             "environment": environment.map(JSONValue.string) ?? .null,
             "recoverySession": recoverySession.map(JSONValue.string) ?? .null,
             "completion": completion.map(JSONValue.string) ?? .null]
        }
    }

    struct ClaudeLoginAttempt {
        let id: String
        let machine: CloudClaudeMachine?
        let recoverySession: String?
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
        releaseCloudClaudeApprovalIfIdle(.cloud)
    }

    func claudeLoginState(_ target: ClaudeLoginTarget) -> ClaudeLoginState {
        if target == .mac { return claudeLogins[target] ?? .init() }
        let state = currentCloudClaudeState
        if let state, ["preparing", "approving", "code", "cancelling"].contains(state.phase) {
            return state
        }
        switch cloudClaudeLogin?(state?.machine, state?.environment, nil) ?? .connectable {
        case .sharedMachine: return .init(phase: "disabled", error: "shared_machine")
        case .connectable:
            guard let state, state.machine == nil || state.phase == "failed" || state.phase == "disabled" else { return .init() }
            return state
        case .ready(let machine):
            guard let state, !state.waitsForGuestUpdate,
                  state.machine == machine.id || (state.machine == nil && state.phase == "failed") else {
                return .init(machine: machine.id, machineName: machine.name, environment: machine.environment)
            }
            return state
        }
    }

    private var currentCloudClaudeState: ClaudeLoginState? {
        cloudClaudeStateAccount == cloudClaudeAccount?() ? claudeLogins[.cloud] : nil
    }

    private func claudeMachine(_ target: ClaudeLoginTarget, preferred: String? = nil, environment: String? = nil, name: String? = nil) throws -> CloudClaudeMachine? {
        guard target == .cloud else { return nil }
        let id = preferred ?? (environment == nil && name == nil ? currentCloudClaudeState?.machine : nil)
        guard case .ready(let machine) = cloudClaudeLogin?(id, environment, name), id == nil || machine.id == id else {
            throw PageError.unavailable("Claude Code is unavailable on this Cloud machine")
        }
        return machine
    }

    func checkClaudeLogin(_ target: ClaudeLoginTarget, machine preferred: String?, environment: String? = nil, name: String? = nil) async {
        guard claudeLoginTasks[target] == nil, claudeLoginAttempts[target] == nil else { return }
        let account = cloudClaudeAccount?()
        let machine: CloudClaudeMachine?
        if target == .cloud, let name, let refreshCloudClaudeMachines {
            let previous = claudeLogins[target]
            let refreshed = await refreshCloudClaudeMachines()
            guard !Task.isCancelled, cloudClaudeAccount?() == account, claudeLogins[target] == previous,
                  claudeLoginTasks[target] == nil, claudeLoginAttempts[target] == nil else { return }
            machine = refreshed ? try? claudeMachine(target, preferred: preferred, environment: environment, name: name) : nil
            if currentCloudClaudeState?.machineName == name, let oldMachine = currentCloudClaudeState?.machine,
               oldMachine != machine?.id {
                claudeLogins[target] = nil
            }
            guard refreshed else { return }
        } else {
            machine = try? claudeMachine(target, preferred: preferred, environment: environment, name: name)
        }
        let state = target == .cloud && ((preferred != nil && currentCloudClaudeState?.machine != preferred)
            || (environment != nil && currentCloudClaudeState?.environment != environment)
            || (name != nil && currentCloudClaudeState?.machineName != name))
            ? ClaudeLoginState() : claudeLoginState(target)
        let failedCloudAttempt = target == .cloud && state.phase == "failed"
        guard target == .mac ? state.phase != "disabled" : !failedCloudAttempt || state.signedIn == true else { return }
        guard target == .mac || machine != nil else { return }
        let previous = claudeLogins[target]
        let stillChecking = {
            self.claudeLoginTasks[target] == nil && self.claudeLoginAttempts[target] == nil &&
                (target == .mac || (self.cloudClaudeAccount?() == account &&
                    self.claudeLogins[target] == previous &&
                    (try? self.claudeMachine(target, preferred: preferred, environment: environment, name: name))?.id == machine?.id))
        }
        do {
            let reply = try await claudeCall(.claudeLoginStatus, "status", ["agent": "claude"], machine: machine)
            guard stillChecking() else { return }
            let signedIn = reply["signedIn"]?.boolValue == true
            let apiKey = reply["apiKey"]?.boolValue == true
            if failedCloudAttempt {
                setClaudeLogin(target, machine, state.phase, error: state.error, apiKey: apiKey, signedIn: signedIn,
                               recoverySession: state.recoverySession)
                return
            }
            setClaudeLogin(target, machine, signedIn ? "connected" : "idle", apiKey: apiKey, signedIn: signedIn)
            if let machine, signedIn { onCloudClaudeSignIn?(machine.id) }
        } catch {
            guard stillChecking(), !failedCloudAttempt, !(error is CancellationError) else { return }
            setClaudeFailure(target, machine, error, requestedEnvironment: environment, requestedName: name)
        }
    }

    func beginClaudeLogin(_ target: ClaudeLoginTarget, replacing: String?, machine requestedMachine: String?, environment: String? = nil, name: String? = nil,
                          recoverySession: String? = nil) throws {
        if let recoverySession {
            guard target == .cloud, requestedMachine != nil, CloudSetup.isConnectionID(recoverySession) else {
                throw PageError.invalidParams("Claude recovery requires a chat and its Cloud machine")
            }
        }
        guard claudeLoginTasks[target] == nil, claudeLoginAttempts[target] == nil,
              !claudeLoginCancellations.contains(target) else { return }
        let preferred = requestedMachine ?? (replacing == "claude-cloud-login" ? currentCloudClaudeState?.machine : nil)
        let prepare = target == .cloud ? prepareCloudClaudeLogin : nil
        let account = cloudClaudeAccount?()
        if target == .cloud {
            guard cloudClaudeAccount == nil || account != nil else { return }
            if name == nil, (preferred == nil || currentCloudClaudeState?.machine == preferred),
               (environment == nil || currentCloudClaudeState?.environment == environment),
               claudeLoginState(target).blocksConnect { return }
        }
        let initial = prepare == nil ? try claudeMachine(target, preferred: preferred, environment: environment, name: name) : nil
        if target == .cloud, !cloudClaudeApproval.acquire(cloudClaudeApprovalOwner) {
            setClaudeLogin(target, initial, "failed", error: "busy",
                           recoverySession: recoverySession, requestedMachine: preferred, requestedEnvironment: environment, requestedName: name)
            return
        }
        setClaudeLogin(target, initial, prepare == nil ? "approving" : "preparing",
                       recoverySession: recoverySession, requestedMachine: preferred, requestedEnvironment: environment, requestedName: name)
        // task-owner: the Settings model owns the preparation and sign-in until they settle.
        claudeLoginTasks[target] = Task { [weak self] in
            guard let self else { return }
            defer {
                claudeLoginTasks[target] = nil
                releaseCloudClaudeApprovalIfIdle(target)
            }
            var machine = initial
            do {
                if let prepare {
                    try checkClaudeAccount(target, account)
                    machine = try await prepare(preferred, environment, name)
                    try checkClaudeAccount(target, account)
                    guard let machine else { return setClaudeLogin(target, nil, "idle") }
                    guard preferred == nil || preferred == machine.id else { throw SettingsCloudClaudeLogin.startFailure }
                    setClaudeLogin(target, machine, "approving", recoverySession: recoverySession)
                }
                var fields = ["agent": "claude"]
                if replacing == "claude-cloud-login" { fields["reauthenticate"] = "true" }
                if let recoverySession { fields["recoverySession"] = recoverySession }
                let started = try await claudeCall(.claudeLoginStart, "start", fields, machine: machine)
                try checkClaudeAccount(target, account)
                if started["signedIn"]?.boolValue == true {
                    if replacing == "claude-cloud-login" { throw PageError(code: "cmux.models.unsupported", message: "Cloud machine does not support reauthentication") }
                    guard claudeLogins[target]?.phase != "cancelling" else {
                        return setClaudeLogin(target, machine, "idle")
                    }
                    setClaudeLogin(target, machine, "approving", apiKey: started["apiKey"]?.boolValue, recoverySession: recoverySession)
                    return try await completeClaudeLogin(target, machine, recoverySession: recoverySession)
                }
                if claudeLogins[target]?.phase != "cancelling" {
                    setClaudeLogin(target, machine, "approving", apiKey: started["apiKey"]?.boolValue, recoverySession: recoverySession)
                }
                guard let id = started["loginId"]?.stringValue else { throw PageError.unavailable("Claude sign-in could not start") }
                claudeLoginAttempts[target] = .init(id: id, machine: machine, recoverySession: recoverySession)
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
                setClaudeLogin(target, machine, "code", recoverySession: recoverySession)
                let remaining = started["expiresAtMs"]?.intValue.map { Double($0) / 1000 - Date.now.timeIntervalSince1970 }
                let timer = DemandTimer(owner: "settings.models.claudeLogin")
                claudeLoginTimers[target] = timer
                timer.schedule(after: .seconds(max(0, min(900, remaining ?? 900)))) { @MainActor [weak self] in
                    guard let self, claudeLoginAttempts[target]?.id == id,
                          target == .mac || cloudClaudeAccount?() == account else { return }
                    dismissSignInPage?(browserOwner)
                    claudeLoginAttempts[target] = nil
                    claudeLoginTimers[target] = nil
                    setClaudeLogin(target, machine, "failed", error: "expired", recoverySession: recoverySession)
                    releaseCloudClaudeApprovalIfIdle(target)
                }
            } catch {
                guard target == .mac || cloudClaudeAccount?() == account,
                      let state = claudeLogins[target], state.phase != "idle" else { return }
                let cancelling = state.phase == "cancelling" || error is CancellationError
                await settleClaudeCancellation(target)
                if !cancelling, target == .mac || cloudClaudeAccount?() == account {
                    setClaudeFailure(target, machine, error, recoverySession: recoverySession, requestedMachine: preferred,
                                     requestedEnvironment: environment, requestedName: name)
                }
            }
        }
    }

    func finishClaudeLogin(_ target: ClaudeLoginTarget, code: String, machine: String?, recoverySession: String?) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard claudeLoginTasks[target] == nil, let attempt = claudeLoginAttempts[target],
              attempt.recoverySession == recoverySession, machine == nil || attempt.machine?.id == machine,
              claudeLoginState(target).phase == "code", Self.isOneWord(code), code.utf8.count <= 4096 else { return }
        let account = cloudClaudeAccount?()
        guard target == .mac || cloudClaudeStateAccount == account else { return }
        claudeLoginTimers.removeValue(forKey: target)?.cancel()
        setClaudeLogin(target, attempt.machine, "approving", recoverySession: attempt.recoverySession)
        // task-owner: the Settings model owns this fallback completion until it settles.
        claudeLoginTasks[target] = Task { [weak self] in
            guard let self else { return }
            defer {
                claudeLoginTasks[target] = nil
                releaseCloudClaudeApprovalIfIdle(target)
            }
            do {
                try await finishClaudeAttempt(target, code: code)
            } catch {
                guard target == .mac || cloudClaudeAccount?() == account else { return }
                let cancelling = claudeLogins[target]?.phase == "cancelling"
                await settleClaudeCancellation(target)
                if !cancelling, !(error is CancellationError), target == .mac || cloudClaudeAccount?() == account {
                    setClaudeFailure(target, attempt.machine, error, recoverySession: attempt.recoverySession)
                }
            }
        }
    }

    func cancelClaudeLogin(_ target: ClaudeLoginTarget, machine: String?, recoverySession: String?) async {
        guard let state = claudeLogins[target], ["preparing", "approving", "code"].contains(state.phase),
              state.recoverySession == recoverySession, machine == nil || state.machine == machine else { return }
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
            if target == .cloud { throw error }
            if !(error is CancellationError) { setClaudeFailure(target, machine, error) }
        }
    }

    private func finishClaudeAttempt(_ target: ClaudeLoginTarget, code: String?) async throws {
        guard let attempt = claudeLoginAttempts[target] else { return }
        let account = cloudClaudeAccount?()
        var fields = ["loginId": attempt.id]
        if let recoverySession = attempt.recoverySession { fields["recoverySession"] = recoverySession }
        if let code { fields["code"] = code }
        let reply = try await claudeCall(.claudeLoginFinish, "finish", fields, machine: attempt.machine)
        try checkClaudeAccount(target, account)
        guard claudeLoginAttempts[target]?.id == attempt.id else { return }
        guard reply["signedIn"]?.boolValue == true else { throw PageError.unavailable("Claude Code did not sign in") }
        claudeLoginAttempts[target] = nil
        dismissSignInPage?("claude:\(attempt.id)")
        try await completeClaudeLogin(target, attempt.machine, recoverySession: attempt.recoverySession)
    }

    private func completeClaudeLogin(_ target: ClaudeLoginTarget, _ machine: CloudClaudeMachine?, recoverySession: String?) async throws {
        let account = cloudClaudeStateAccount
        try checkClaudeAccount(target, account)
        await refresh()
        try checkClaudeAccount(target, account)
        setClaudeLogin(target, machine, "connected", signedIn: true, completion: UUID().uuidString, recoverySession: recoverySession)
        if let machine { onCloudClaudeSignIn?(machine.id) }
    }

    private func checkClaudeAccount(_ target: ClaudeLoginTarget, _ account: [String?]?) throws {
        guard target == .cloud else { return }
        try Task.checkCancellation()
        guard cloudClaudeAccount?() == account else { throw CancellationError() }
    }

    private func settleClaudeCancellation(_ target: ClaudeLoginTarget) async {
        guard claudeLoginCancellations.insert(target).inserted else { return }
        defer {
            claudeLoginCancellations.remove(target)
            releaseCloudClaudeApprovalIfIdle(target)
        }
        let account = cloudClaudeStateAccount
        if let attempt = claudeLoginAttempts.removeValue(forKey: target) {
            dismissSignInPage?("claude:\(attempt.id)")
            _ = try? await claudeCall(.claudeLoginCancel, "cancel", ["loginId": attempt.id], machine: attempt.machine)
        }
        guard target == .mac || cloudClaudeAccount?() == account else { return }
        claudeLoginTimers.removeValue(forKey: target)?.cancel()
        let stillSignedIn = target == .cloud && claudeLogins[target]?.signedIn == true
        claudeLogins[target]?.phase = stillSignedIn ? "connected" : "idle"
    }

    private func releaseCloudClaudeApprovalIfIdle(_ target: ClaudeLoginTarget) {
        if target == .cloud, claudeLoginTasks[target] == nil, claudeLoginAttempts[target] == nil,
           !claudeLoginCancellations.contains(target) {
            cloudClaudeApproval.release(cloudClaudeApprovalOwner)
        }
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
            let message = method == .claudeLoginLogout ? "Claude sign-out was refused" : "Claude sign-in was refused"
            throw PageError(code: "cmux.models.\(reason)", message: message)
        }
        return reply
    }

    private func setClaudeFailure(_ target: ClaudeLoginTarget, _ machine: CloudClaudeMachine?, _ error: any Error,
                                  recoverySession: String? = nil, requestedMachine: String? = nil,
                                  requestedEnvironment: String? = nil, requestedName: String? = nil) {
        let refusal = Self.daemonRefusal(error)
        let reason = refusal == "unknown_login" ? "expired" : refusal ?? "failed"
        let disabled = ["cli_missing", "update_claude", "shared_machine", "unsupported"].contains(reason)
        setClaudeLogin(target, machine, disabled ? "disabled" : "failed", error: reason, recoverySession: recoverySession,
                       requestedMachine: requestedMachine, requestedEnvironment: requestedEnvironment, requestedName: requestedName,
                       waitsForGuestUpdate: target == .cloud && machine == nil && reason == "unsupported")
    }

    private func setClaudeLogin(_ target: ClaudeLoginTarget, _ machine: CloudClaudeMachine?, _ phase: String,
                                error: String? = nil, apiKey: Bool? = nil, signedIn: Bool? = nil, completion: String? = nil,
                                recoverySession: String? = nil, requestedMachine: String? = nil, requestedEnvironment: String? = nil,
                                requestedName: String? = nil, waitsForGuestUpdate: Bool = false) {
        let account = cloudClaudeAccount?()
        let machineID = machine?.id ?? requestedMachine
        let previous = claudeLogins[target].flatMap {
            $0.machine == machineID && (target == .mac || cloudClaudeStateAccount == account) ? $0 : nil
        }
        if target == .cloud { cloudClaudeStateAccount = account }
        let preparingMachine: ClaudeLoginState? = phase == "preparing" && machineID != nil ? previous : nil
        let keepsApiKey: Bool = apiKey ?? previous?.apiKey ?? false
        let keepsSignedIn: Bool? = signedIn ?? previous?.signedIn
        let machineName: String? = machine?.name ?? requestedName ?? preparingMachine?.machineName
        let environment: String? = machine?.environment ?? requestedEnvironment ?? preparingMachine?.environment
        let sameRecovery: ClaudeLoginState? = previous?.recoverySession == recoverySession ? previous : nil
        let keptCompletion: String? = completion ?? sameRecovery?.completion
        claudeLogins[target] = ClaudeLoginState(phase: phase, error: error, apiKey: keepsApiKey, signedIn: keepsSignedIn,
                                                machine: machineID, machineName: machineName, environment: environment,
                                                recoverySession: recoverySession, completion: keptCompletion,
                                                waitsForGuestUpdate: waitsForGuestUpdate)
    }
}
