public import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
import Observation
import CmuxNextWakeups

/// Settings > Models (cmux-tui/docs/model-connections.md): the person's model connections from acpmux
/// (`_acpmux/connections`), the team's shared keys and the team's members policy, for
/// the React Settings page's `cmux.settings.models.state|run` and its `.changed` stream.
///
/// Every run maps to one owner: acpmux for the person's connections (order, spread, enable, remove,
/// Sign in with ChatGPT, or an API key), Claude Code for its own login, and the owner API for the team's keys
/// (``TeamAgentKeys``) and policy (``TeamModelsPolicy``). Revision 2: no team gateway.
///
/// A pasted API key goes into this Mac's Keychain (``ModelKeyStoring``) before anything
/// else sees it; acpmux gets only its `keychain:ITEM` reference. It never reaches page state, a log or a file.
/// Spread lives in the settings schema (`models.spreadUsage`, so the palette, `cmux settings` and MCP
/// reach it); this mirrors it into acpmux, which keeps a copy in its bindings.
@MainActor
@Observable
public final class SettingsModels {
    /// acpmux's connection kinds and providers the page draws (`ModelConnection`).
    nonisolated static let kinds: Set<String> = ["codex-login", "claude-login", "subscription", "native-login", "chatgpt-plan", "claude-token", "grok-plan", "copilot-plan", "kimi-plan", "api-key", "endpoint"]
    nonisolated static let providers: Set<String> = ["openai", "anthropic", "openrouter", "google", "vertex-express", "xai"]
    /// `chatgpt.wait` rounds (each up to 25 s) before an attempt is given up: about 15 minutes.
    nonisolated static let chatgptRounds = 36
    /// Failed `chatgpt.wait` calls in a row (no answer) before the attempt is given up.
    nonisolated static let chatgptFailures = 3
    nonisolated static let keyLimit = 16_384

    /// The page's connections (`ModelConnection`), in acpmux's order.
    private(set) var connections: [JSONValue] = []
    /// acpmux's `spread`; the page shows the setting's value when there is one.
    private(set) var daemonSpread = true
    /// Whether acpmux answered `_acpmux/connections` at the last read.
    private(set) var available = false
    private var claudeCodeAvailable: Bool?
    private(set) var read = false
    private(set) var chatgptAttempt: String?
    private(set) var chatgptError: String?
    var chatgptDevice = ChatGPTDeviceState.idle
    var deviceProvider = ModelDeviceProvider.chatgpt
    var deviceRegion: String?
    var deviceTarget: String?
    @ObservationIgnored var chatgptDeviceRunID = UUID()
    @ObservationIgnored var chatgptDeviceTask: Task<Void, Never>?
    @ObservationIgnored var chatgptDeviceEnvironment: AcpmuxEnvironment?
    var claudeLogins: [ClaudeLoginTarget: ClaudeLoginState] = [:]
    @ObservationIgnored var claudeLoginTasks: [ClaudeLoginTarget: Task<Void, Never>] = [:]
    @ObservationIgnored var claudeLoginTimers: [ClaudeLoginTarget: DemandTimer] = [:]
    @ObservationIgnored var onCloudClaudeSignIn: (@MainActor (String) -> Void)?
    @ObservationIgnored var presentClaudeCallback: CloudClaudeMachine.CallbackOpener?
    @ObservationIgnored var claudeLoginAttempts: [ClaudeLoginTarget: ClaudeLoginAttempt] = [:]
    @ObservationIgnored var claudeLoginCancellations: Set<ClaudeLoginTarget> = []
    nonisolated let cloudClaudeApproval: CloudClaudeApproval
    nonisolated let cloudClaudeApprovalOwner = UUID()
    /// The current owner machine, keeping the machine this dialog used while it is still ready.
    @ObservationIgnored public var cloudClaudeLogin: (@MainActor (String?, String?, String?) -> CloudClaudeLogin)?
    /// Prepares an owned machine for Connect. Nil means the Cloud create card handled the request.
    @ObservationIgnored public var prepareCloudClaudeLogin: (@MainActor (String?, String?, String?) async throws -> CloudClaudeMachine?)?
    @ObservationIgnored var refreshCloudClaudeMachines: (@MainActor () async -> Bool)?
    @ObservationIgnored var cloudClaudeAccount: (@MainActor @Sendable () -> [String?]?)?
    @ObservationIgnored var cloudClaudeAccountWatch: Task<Void, Never>?
    @ObservationIgnored var cloudClaudeStateAccount: [String?]?

    /// The one-click Claude connection (`claude_token.begin`): its attempt, phase (`starting`,
    /// `signing_in`, `saving`), the last attempt's error, and whether the last attempt saved a token
    /// (a Cancel, or a run the daemon cancelled, ends with neither an error nor `saved`).
    private(set) var claudeTokenAttempt: String?
    private(set) var claudeTokenPhase: String?
    private(set) var claudeTokenError: String?
    private(set) var claudeTokenSaved = false

    var hasDaemonOverride: Bool { call != nil }

    @ObservationIgnored let environment: @MainActor () async -> AcpmuxEnvironment?
    @ObservationIgnored private let call: (@Sendable (AcpmuxEnvironment, AcpmuxHarnessMethod, [String: any Sendable]) async throws -> Data)?
    @ObservationIgnored private let keys: any ModelKeyStoring
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored var presentSignInPage: (@MainActor (URL, String) async -> Bool)?
    @ObservationIgnored var dismissSignInPage: (@MainActor (String) -> Void)?
    @ObservationIgnored package var harnesses: SettingsHarnesses?
    @ObservationIgnored private let team: @MainActor () -> (id: String, name: String)?
    @ObservationIgnored private let agentKeys: TeamAgentKeys?
    @ObservationIgnored private let policy: TeamModelsPolicy?
    @ObservationIgnored private let spreadSetting: (@MainActor () -> Bool)?
    @ObservationIgnored private let writeSpreadSetting: (@MainActor (Bool) async throws -> Void)?
    /// Confirmed credential runners and whether any listed machine has yet to report support.
    @ObservationIgnored public var cloudHarnesses: (@MainActor (_ subscription: Bool, _ offline: Set<String>) -> (confirmed: Set<String>, pending: Bool))?
    @ObservationIgnored public var cloudUnlinkedMachines: (@MainActor () -> Set<String>)?
    @ObservationIgnored public var cloudRunnerConnectWait: Duration = .seconds(180)
    @ObservationIgnored private var cloudRunnerWatch: Task<Void, Never>?
    @ObservationIgnored private var cloudRunnerTimers: [String: DemandTimer] = [:]
    private var cloudOfflineMachines: Set<String> = []
    @ObservationIgnored private var generation = 0
    /// Called each time this Mac's connections are read or change (a run's answer, a watched change): a
    /// Cloud chat waiting on Set up Cloud checks again (``CloudSetup/connectionsChanged()``, set by the app).
    @ObservationIgnored public var onConnections: (@MainActor () -> Void)?

    nonisolated deinit {
        cloudClaudeAccountWatch?.cancel()
        let approval = cloudClaudeApproval, owner = cloudClaudeApprovalOwner
        MainDelivery().run { approval.release(owner) }
    }
    @ObservationIgnored private(set) var chatgptTask: Task<Void, Never>?
    @ObservationIgnored private(set) var claudeTokenTask: Task<Void, Never>?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var watchEnvironment: AcpmuxEnvironment?

    /// - Parameters:
    ///   - environment: waits for the local host to finish starting before returning its socket.
    ///   - call: a test's stand-in for the daemon; nil calls it (``AcpmuxEnvironment/harness(_:params:)``).
    ///   - openURL: opens the ChatGPT sign-in page in the person's browser, in the background.
    ///   - team: the active team's id and name; nil signed out or for the personal team.
    ///   - spreadSetting, writeSpreadSetting: `models.spreadUsage`, read and written through the settings writer.
    ///   - cloudClaudeApproval: the app's approval slot shared across Settings windows.
    public init(environment: @escaping @MainActor () async -> AcpmuxEnvironment?,
                call: (@Sendable (AcpmuxEnvironment, AcpmuxHarnessMethod, [String: any Sendable]) async throws -> Data)? = nil,
                keys: any ModelKeyStoring,
                openURL: @escaping @MainActor (URL) -> Void,
                team: @escaping @MainActor () -> (id: String, name: String)? = { nil },
                agentKeys: TeamAgentKeys? = nil,
                policy: TeamModelsPolicy? = nil,
                spreadSetting: (@MainActor () -> Bool)? = nil,
                writeSpreadSetting: (@MainActor (Bool) async throws -> Void)? = nil,
                cloudClaudeApproval: CloudClaudeApproval = CloudClaudeApproval(),
                harnesses: SettingsHarnesses? = nil) {
        self.environment = environment
        self.call = call
        self.keys = keys
        self.openURL = openURL
        self.team = team
        self.agentKeys = agentKeys
        self.policy = policy
        self.spreadSetting = spreadSetting
        self.writeSpreadSetting = writeSpreadSetting
        self.cloudClaudeApproval = cloudClaudeApproval
        self.harnesses = harnesses
    }

    // MARK: State

    /// The page's `ModelsState` (webviews/src/pages/settings/ops.ts).
    public var state: JSONValue {
        let active = team()
        let keys: [JSONValue] = (active == nil ? [] : agentKeys?.currentAgents ?? []).compactMap { row -> JSONValue? in
            guard let agent = row["agent"]?.stringValue, TeamAgentKeys.agents.contains(agent) else { return nil }
            return ["agent": .string(agent), "set": .bool(row["set"]?.boolValue == true),
                    "last4": row["hint"]?.stringValue.map(JSONValue.string) ?? .null]
        }
        let members: JSONValue = active == nil ? .null : policy?.current.map { policy -> JSONValue in
            ["ownConnections": .bool(policy.ownConnections), "chooseRunout": .bool(policy.chooseRunout), "canEdit": .bool(policy.canEdit)]
        } ?? .null
        let offline = cloudOfflineMachines.intersection(cloudUnlinkedMachines?() ?? [])
        let endpoints = cloudHarnesses?(false, offline)
        let subscriptions = cloudHarnesses?(true, offline)
        return [
            "connectionTools": .bool(true),
            "cloudHarnesses": .array((endpoints?.confirmed ?? []).sorted().map(JSONValue.string)),
            "cloudSubscriptionHarnesses": .array((subscriptions?.confirmed ?? []).sorted().map(JSONValue.string)),
            "cloudRunnersOffline": .bool(!offline.isEmpty),
            "cloudEndpointRunnersPending": .bool(endpoints?.pending ?? false),
            "cloudSubscriptionRunnersPending": .bool(subscriptions?.pending ?? false),
            "personal": ["connections": .array(connections), "spread": .bool(spread), "available": .bool(available)],
            "organization": [
                "team": active.map { team -> JSONValue in ["id": .string(team.id), "name": .string(team.name)] } ?? .null,
                "canEdit": .bool(active != nil && agentKeys?.canManage == true),
                "keys": .array(keys),
            ],
            "members": members,
            "claudeLogin": claudeLoginState(.mac).pageState,
            "cloudClaudeLogin": claudeLoginState(.cloud).pageState,
            "cloudClaudeApprovalBusy": .bool(cloudClaudeApproval.isBusy(for: cloudClaudeApprovalOwner)),
            "claudeCodeAvailable": claudeCodeAvailable.map(JSONValue.bool) ?? .null,
            "chatgpt": ["attempt": chatgptAttempt.map(JSONValue.string) ?? .null, "error": chatgptError.map(JSONValue.string) ?? .null],
            "chatgptDevice": chatgptDevice.pageState,
            "deviceProvider": .string(deviceProvider.rawValue),
            "deviceRegion": deviceRegion.map(JSONValue.string) ?? .null,
            "deviceTarget": deviceTarget.map(JSONValue.string) ?? .null,
            "claudeToken": ["attempt": claudeTokenAttempt.map(JSONValue.string) ?? .null,
                            "phase": claudeTokenPhase.map(JSONValue.string) ?? .null,
                            "error": claudeTokenError.map(JSONValue.string) ?? .null,
                            "saved": .bool(claudeTokenSaved)],
        ]
    }

    /// The switch the page shows: the setting (the one writer) when there is one, else acpmux's copy.
    var spread: Bool { spreadSetting?() ?? daemonSpread }

    /// The state after the first read (the page's first `state` call reads it).
    public func loadedState() async -> JSONValue {
        if !read || !available { await refresh() }
        return state
    }

    /// Reads acpmux's connections, the team's keys and policy again. Only the newest read writes.
    public func refresh() async {
        generation += 1
        let mine = generation
        read = true
        async let teamRead: Void = refreshTeam()
        do {
            let environment = try await requireDaemon()
            let reply = try JSONValue.parse(try await daemon(environment, .connections, [:]))
            if mine == generation {
                apply(reply)
                watchEnvironment = environment
                startWatch()
                // The setting is the writer: an acpmux copy that differs (another client, an older run) follows it.
                if let wanted = spreadSetting?(), wanted != daemonSpread {
                    try? await push(spread: wanted, environment)
                }
            }
        } catch {
            if mine == generation {
                available = false
                watchEnvironment = nil
                watch?.cancel()
                watch = nil
            }
        }
        await teamRead
    }

    private func refreshTeam() async {
        guard team() != nil else { return }
        // Each owns its own staleness check.
        await agentKeys?.refresh()
        await policy?.refresh()
    }

    /// An acpmux `ConnectionsState`: its connections as the page draws them, and its spread.
    func apply(_ reply: JSONValue, preserveNativeSignIns: Bool = false) {
        var updated = (reply["connections"]?.arrayValue ?? []).compactMap(Self.connection)
        if preserveNativeSignIns {
            let ids = Set(updated.compactMap { $0["id"]?.stringValue })
            updated.append(contentsOf: connections.filter {
                $0["kind"]?.stringValue == "native-login" && !ids.contains($0["id"]?.stringValue ?? "")
            })
        }
        connections = updated
        if let installed = reply["claude_code_available"]?.boolValue { claudeCodeAvailable = installed }
        if let on = reply["spread"]?.boolValue { daemonSpread = on }
        available = true
        onConnections?()
    }

    /// One acpmux `Connection` as the page's `ModelConnection` (camelCase). `servesCloud`: whether it can
    /// serve a Cloud chat (Revision 2: the Mac CLI logins do not).
    nonisolated static func connection(_ value: JSONValue) -> JSONValue? {
        guard let id = value["id"]?.stringValue, !id.isEmpty, let kind = value["kind"]?.stringValue, kinds.contains(kind) else { return nil }
        let strings = { (key: String, camel: String) -> JSONValue in
            .array((value[key]?.arrayValue ?? value[camel]?.arrayValue ?? []).compactMap { $0.stringValue.map(JSONValue.string) })
        }
        let text = { (key: String) -> JSONValue in value[key]?.stringValue.map(JSONValue.string) ?? .null }
        let provider = value["provider"]?.stringValue.flatMap { provider in
            if kind == "endpoint" || kind == "grok-plan" || kind == "copilot-plan" || kind == "kimi-plan" || providers.contains(provider) { return provider }
            if kind == "native-login", ["gemini", "grok", "cursor"].contains(provider) { return provider }
            return nil
        } ?? (kind == "claude-login" || kind == "claude-token" ? "anthropic" : "openai")
        let servesCloud = value["serves_cloud"]?.boolValue ?? value["servesCloud"]?.boolValue ?? false
        return [
            "id": .string(id), "kind": .string(kind), "provider": .string(provider),
            "credentialInstance": text("credential_instance"),
            "keyRevision": text("key_revision"),
            "families": strings("families", "families"), "label": .string(value["label"]?.stringValue ?? id),
            "email": text("email"), "plan": text("plan"),
            "signedIn": .bool(value["signed_in"]?.boolValue ?? value["signedIn"]?.boolValue ?? false),
            "signInReason": text("sign_in_reason"),
            "enabled": .bool(value["enabled"]?.boolValue ?? false),
            "defaultFor": strings("default_for", "defaultFor"),
            "servesCloud": .bool(servesCloud),
            "canServeCloud": .bool(value["can_serve_cloud"]?.boolValue ?? servesCloud),
            "cloudFamilies": value["cloud_families"] ?? strings("families", "families"),
            "canCheckAccess": .bool(value["can_check_access"]?.boolValue ?? false),
            "canReplaceKey": .bool(value["can_replace_key"]?.boolValue ?? false),
            "endpoint": value["endpoint"] ?? .null,
            "launchHarness": text("launch_harness"),
            "expiresAt": value["expires_at"] ?? .null,
        ]
    }

    // MARK: Watching

    /// The page shows the card: each `_acpmux/connections.changed` carries acpmux's whole
    /// `ConnectionsState`, which shows at once (a note without one reads the state again).
    public func beginWatching() {
        watchers += 1
        startWatch()
        if cloudRunnerWatch == nil, cloudUnlinkedMachines != nil {
            // task-owner: cloudRunnerWatch; cancelled when the models subscription ends.
            cloudRunnerWatch = Task { [weak self] in
                for await unlinked in ObservationStream({ [weak self] in self?.cloudUnlinkedMachines?() ?? [] }) {
                    self?.watchCloudRunnerLinks(unlinked)
                }
            }
        }
    }

    private func watchCloudRunnerLinks(_ unlinked: Set<String>) {
        cloudOfflineMachines.formIntersection(unlinked)
        for id in Set(cloudRunnerTimers.keys).subtracting(unlinked) {
            cloudRunnerTimers.removeValue(forKey: id)?.cancel()
        }
        for id in unlinked where cloudRunnerTimers[id] == nil && !cloudOfflineMachines.contains(id) {
            let timer = DemandTimer(owner: "settings.cloud.runnerLink")
            cloudRunnerTimers[id] = timer
            timer.schedule(after: cloudRunnerConnectWait) { @MainActor [weak self] in
                guard let self else { return }
                self.cloudRunnerTimers[id] = nil
                if self.cloudUnlinkedMachines?().contains(id) == true {
                    self.cloudOfflineMachines.insert(id)
                }
            }
        }
    }

    /// The watch starts once the page subscribes and the first connections read succeeds.
    private func startWatch() {
        guard watchers > 0, watch == nil, let watchEnvironment else { return }
        let (changes, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
        let socket = watchEnvironment.watchConnections(onEnd: { continuation.finish() }) { continuation.yield($0) }
        // task-owner: SettingsModels.watch: one update per acpmux change while a page shows the card; endWatching cancels it.
        watch = Task { [weak self] in
            await withTaskCancellationHandler {
                for await line in changes { await self?.changed(line) }
            } onCancel: {
                socket.cancel()
                continuation.finish()
            }
            if !Task.isCancelled { self?.watch = nil }
        }
    }

    /// One `_acpmux/connections.changed` line: its state shows at once and any read in flight answers no
    /// more; a note without a state reads it again.
    func changed(_ line: Data) async {
        guard let state = (try? JSONValue.parse(line))?["params"], state["connections"] != nil else { return await refresh() }
        generation += 1
        apply(state)
    }

    public func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        cloudRunnerWatch?.cancel()
        cloudRunnerWatch = nil
        for timer in cloudRunnerTimers.values { timer.cancel() }
        cloudRunnerTimers.removeAll()
        watch?.cancel()
        watch = nil
        if claudeLogins.values.contains(where: { ["preparing", "approving", "code"].contains($0.phase) }) {
            // task-owner: the page's last subscription ended. Release any approval this model owns.
            Task {
                for target in [ClaudeLoginTarget.mac, .cloud] {
                    guard watchers == 0, let state = claudeLogins[target] else { continue }
                    await cancelClaudeLogin(target, machine: state.machine, recoverySession: state.recoverySession)
                }
            }
        }
    }

    // MARK: Runs

    /// One page gesture (`cmux.settings.models.run`, `ModelsRun`). Every change needs the person's own
    /// input on the page (a click, or a confirmed user call); `refresh` and `focus` do not.
    public func run(_ params: JSONValue, context: PageCallContext?) async throws -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        if action == "refresh" || action == "focus" {
            await refresh()
            return .object([:])
        }
        if action == "checkClaudeLogin" {
            await checkClaudeLogin(params["cloud"]?.boolValue == true ? .cloud : .mac,
                                   machine: params["machine"]?.stringValue, environment: params["environment"]?.stringValue, name: params["machineName"]?.stringValue)
            return .object([:])
        }
        if action == "closeKeyPage", let url = params["url"]?.stringValue {
            dismissSignInPage?("key:\(url)")
            return .object([:])
        }
        guard context?.userGesture == true || context?.isConfirmedUser == true else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
        switch action {
        case "order":
            guard let ids = params["ids"]?.arrayValue, ids.count <= 256 else { throw PageError.invalidParams("order needs ids") }
            let list = ids.compactMap(\.stringValue)
            guard list.count == ids.count, Set(list).count == list.count else { throw PageError.invalidParams("order needs distinct connection ids") }
            try await mutate(.connectionsOrderSet, ["ids": list])
        case "spread":
            guard let on = params["on"]?.boolValue else { throw PageError.invalidParams("spread needs on") }
            // The setting first (the palette, CLI and MCP read it), then acpmux's copy.
            if let writeSpreadSetting { try await writeSpreadSetting(on) }
            let environment = try await requireDaemon()
            try await push(spread: on, environment)
        case "enable":
            guard let id = listedID(params), let on = params["on"]?.boolValue else { throw PageError.invalidParams("enable needs a listed id and on") }
            _ = try await daemon(try requireDaemon(), .accountSet, ["id": id, "enabled": on])
            await refresh()
        case "setCloud":
            guard let id = listedID(params), let on = params["on"]?.boolValue,
                  let instance = params["instance"]?.stringValue,
                  let keyRevision = params["keyRevision"]?.stringValue,
                  connections.contains(where: {
                      $0["id"]?.stringValue == id && $0["kind"]?.stringValue == "api-key"
                          && $0["credentialInstance"]?.stringValue == instance
                          && $0["keyRevision"]?.stringValue == keyRevision
                  }) else {
                throw PageError.invalidParams("setCloud needs the listed API-key connection instance and on")
            }
            try await mutate(.accountSet, ["id": id, "instance": instance, "cloudUse": on, "keyRevision": keyRevision])
        case "rename":
            guard let id = listedID(params), id != "claude-login",
                  let name = params["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 128 else { throw PageError.invalidParams("rename needs a listed route and a name") }
            guard let instance = params["instance"], instance.stringValue != nil || (id == "codex-login" && instance == .null),
                  connections.contains(where: { $0["id"]?.stringValue == id && $0["credentialInstance"] == instance }) else {
                throw PageError.invalidParams("rename needs the listed connection instance")
            }
            let expected = instance.stringValue.map { $0 as any Sendable } ?? NSNull()
            try await mutate(.accountSet, ["id": id, "name": name, "instance": expected])
        case "checkAccess":
            return try await checkAccess(params)
        case "remove":
            guard let id = listedID(params), let instance = params["instance"]?.stringValue,
                  connections.contains(where: { $0["id"]?.stringValue == id && $0["credentialInstance"]?.stringValue == instance }) else {
                throw PageError.invalidParams("remove needs the listed connection instance")
            }
            try await mutate(.connectionsRemove, ["id": id, "instance": instance])
        case "connectChatGPT":
            return try await connectChatGPT(id: params["id"]?.stringValue)
        case "cancelChatGPT":
            await cancelChatGPT()
        case "connectChatGPTDevice":
            let id = params["id"]?.stringValue
            let name = params["provider"]?.stringValue ?? "chatgpt"
            guard let provider = ModelDeviceProvider(rawValue: name),
                  id == nil || connections.contains(where: {
                      $0["id"]?.stringValue == id && $0["kind"]?.stringValue == provider.connectionKind
                  }) else { throw PageError.invalidParams("sign-in needs a matching subscription") }
            if case .showingChallenge(let challenge) = chatgptDevice,
               Double(challenge.expiresAt) <= Date.now.timeIntervalSince1970 {
                await cancelChatGPTDevice()
            }
            connectChatGPTDevice(
                replacing: id, openBrowser: params["openBrowser"]?.boolValue == true, provider: provider,
                region: params["region"]?.stringValue, servesCloud: params["servesCloud"]?.boolValue
            )
        case "openChatGPTDevice":
            if case .showingChallenge(let challenge) = chatgptDevice,
               Double(challenge.expiresAt) > Date.now.timeIntervalSince1970 {
                try await openSignIn(challenge.url, owner: "device:\(chatgptDeviceRunID)")
            }
        case "cancelChatGPTDevice":
            await cancelChatGPTDevice()
        case "connectClaude", "finishClaudeLogin", "cancelClaudeLogin", "signOutClaude":
            let target: ClaudeLoginTarget = params["cloud"]?.boolValue == true ? .cloud : .mac
            switch action {
            case "connectClaude":
                try beginClaudeLogin(target, replacing: claudeReplacement(params, target: target),
                                     machine: params["machine"]?.stringValue, environment: params["environment"]?.stringValue, name: params["machineName"]?.stringValue,
                                     recoverySession: params["recoverySession"]?.stringValue)
            case "finishClaudeLogin":
                finishClaudeLogin(target, code: params["code"]?.stringValue ?? "", machine: params["machine"]?.stringValue,
                                  recoverySession: params["recoverySession"]?.stringValue)
            case "cancelClaudeLogin":
                await cancelClaudeLogin(target, machine: params["machine"]?.stringValue, recoverySession: params["recoverySession"]?.stringValue)
            default:
                try await signOutClaude(target, machine: params["machine"]?.stringValue)
            }
        case "connectClaudeToken":
            return try await connectClaudeToken(label: params["label"]?.stringValue)
        case "claudeTokenCode":
            try await claudeTokenCode(params["code"]?.stringValue ?? "")
        case "cancelClaudeToken":
            await cancelClaudeToken()
        case "claudeSetupToken":
            // A daemon with the one-click run (`claude_token.begin`) needs no terminal: the app runs
            // `claude setup-token` itself and the token is never shown. An older one: the terminal tab.
            do { return try await connectClaudeToken(label: params["label"]?.stringValue) } catch let error as PageError where error.code == "cmux.models.unsupported" {
                guard let harnesses else { throw PageError.unavailable("no terminal tab could be opened on this Mac") }
                try await harnesses.typeLine("claude setup-token")
            }
        case "addClaudeToken":
            let replacing: (id: String, instance: String)?
            if let replacement = params["replacement"] {
                guard let id = replacement["id"]?.stringValue, let instance = replacement["instance"]?.stringValue,
                      connections.contains(where: {
                          $0["id"]?.stringValue == id && $0["kind"]?.stringValue == "claude-token"
                              && $0["credentialInstance"]?.stringValue == instance
                      }) else {
                    throw PageError.invalidParams("replacement needs the listed Claude token instance")
                }
                replacing = (id, instance)
            } else {
                replacing = nil
            }
            try await addClaudeToken(params["token"]?.stringValue ?? "", label: params["label"]?.stringValue, replacing: replacing)
        case "addKey":
            let provider = params["provider"]?.stringValue ?? ""
            let key = params["key"]?.stringValue ?? ""
            let replacement: (id: String, instance: String)?
            if let replace = params["replace"]?.stringValue {
                guard let instance = params["replaceInstance"]?.stringValue, connections.contains(where: {
                    $0["id"]?.stringValue == replace && $0["provider"]?.stringValue == provider
                        && $0["canReplaceKey"]?.boolValue == true && $0["credentialInstance"]?.stringValue == instance
                }) else {
                    throw PageError.invalidParams("replacement needs a listed API-key connection")
                }
                replacement = (replace, instance)
            } else {
                replacement = nil
            }
            if params["verifyAccess"]?.boolValue == true {
                let trimmed = Self.withoutWhitespace(key)
                guard Self.providers.contains(provider), Self.isModelAPIKey(trimmed) else {
                    throw PageError.invalidParams("addKey needs a known provider and a key with no spaces")
                }
                let result: JSONValue
                do {
                    result = try await checkAccess(["provider": .string(provider), "key": .string(trimmed)])
                } catch let error as PageError where error.code == "cmux.protocol.unavailable" || error.code == "cmux.page.unavailable" {
                    return ["failure": .string(error.message), "verificationFailed": true]
                }
                if let failure = result["failure"]?.stringValue {
                    return ["failure": .string(failure), "verificationFailed": true]
                }
                guard result["models"]?.arrayValue != nil else {
                    throw PageError.unavailable("the local acpmux could not check model access")
                }
            }
            try await addKey(provider: provider, key: key, label: params["label"]?.stringValue, replacing: replacement, servesCloud: params["servesCloud"]?.boolValue,
                             checkStoredKey: params["verifyAccess"]?.boolValue == nil)
        case "orgKey":
            // `key: null` removes; a missing key is a mistake, not a removal.
            guard let key = params["key"] else { throw PageError.invalidParams("orgKey needs key (a key, or null to remove)") }
            try await orgKey(agent: params["agent"]?.stringValue ?? "", key: key.stringValue, kind: params["kind"]?.stringValue)
        case "members":
            guard let policy, team() != nil else { throw PageError.unavailable("no team") }
            let own = params["ownConnections"]?.boolValue, runout = params["chooseRunout"]?.boolValue
            guard own != nil || runout != nil else { throw PageError.invalidParams("members needs ownConnections or chooseRunout") }
            do { try await policy.set(ownConnections: own, chooseRunout: runout) } catch { throw Self.pageError(error) }
        default:
            throw PageError.invalidParams("unknown models action \(action)")
        }
        return .object([:])
    }

    private func claudeReplacement(_ params: JSONValue, target: ClaudeLoginTarget) throws -> String? {
        guard let id = params["replace"]?.stringValue else { return nil }
        if target == .cloud, id == "claude-cloud-login" { return id }
        guard connections.contains(where: { $0["id"]?.stringValue == id && $0["kind"]?.stringValue == "claude-token" }) else {
            throw PageError.invalidParams("replacement needs a listed Claude connection")
        }
        return id
    }

    /// A connection id the last read listed.
    private func listedID(_ params: JSONValue) -> String? {
        guard let id = params["id"]?.stringValue, connections.contains(where: { $0["id"]?.stringValue == id }) else { return nil }
        return id
    }

    /// Checks the draft or saved key in acpmux without storing the draft or sending a prompt.
    private func checkAccess(_ params: JSONValue) async throws -> JSONValue {
        var request: [String: any Sendable] = ["listModels": true]
        if params["id"] != nil {
            guard let id = listedID(params), connections.contains(where: {
                $0["id"]?.stringValue == id && $0["canCheckAccess"]?.boolValue == true
            }) else { throw PageError.invalidParams("checkAccess needs a listed API-key connection") }
            request["id"] = id
        } else {
            if let provider = params["provider"]?.stringValue, Self.providers.contains(provider) {
                request["provider"] = provider
            } else if let base = params["baseUrl"]?.stringValue, !base.isEmpty, base.utf8.count <= 2048 {
                request["baseUrl"] = base
            } else {
                throw PageError.invalidParams("checkAccess needs a provider or base URL")
            }
            if let key = params["key"]?.stringValue {
                guard Self.isModelAPIKey(key) else { throw PageError.invalidParams("invalid API key format") }
                request["apiKey"] = key
            }
        }
        let environment = try await requireDaemon()
        let method = AcpmuxHarnessMethod.routeTest
        if hasDaemonOverride { return try JSONValue.parse(try await daemon(environment, method, request)) }
        guard let line = await AcpmuxPersonLine.open(environment, deadline: .seconds(15)) else {
            throw PageError.unavailable("cannot reach the local acpmux")
        }
        defer { line.close() }
        guard line.isPerson, let reply = await line.call(method.rawValue, request) else {
            throw PageError.unavailable("the local acpmux could not check model access")
        }
        return try JSONValue.parse(JSONSerialization.data(withJSONObject: reply))
    }

    func requireDaemonEnvironment() async throws -> AcpmuxEnvironment { try await requireDaemon() }

    // The +Live extension's reach into this object's state (its own file cannot see the private members).
    func setChatGPT(attempt: String?, error: String?) {
        chatgptAttempt = attempt
        chatgptError = error
    }

    func openSignIn(_ url: URL, owner: String) async throws {
        // Live Settings uses the app browser; other hosts can supply their own opener.
        if let presentSignInPage, await presentSignInPage(url, owner) {
            return
        }
        if let open = harnesses?.openSignInPage, await open(url) != nil { return }
        openURL(url)
    }

    func setClaudeToken(attempt: String?, phase: String?, error: String?, saved: Bool = false) {
        claudeTokenAttempt = attempt
        claudeTokenPhase = phase
        claudeTokenError = error
        claudeTokenSaved = saved
    }

    func replaceClaudeTokenTask(_ task: Task<Void, Never>?) {
        claudeTokenTask?.cancel()
        claudeTokenTask = task
    }

    func replaceChatGPTTask(_ task: Task<Void, Never>?) {
        chatgptTask?.cancel()
        chatgptTask = task
    }

    func storeKey(_ key: String, provider: String) async throws -> String {
        do { return try await keys.store(key, provider: provider) } catch { throw Self.pageError(error) }
    }

    func deleteKey(_ reference: String) async { await keys.delete(reference) }
    var teamAgentKeys: TeamAgentKeys? { agentKeys }
    var hasTeam: Bool { team() != nil }

    private func requireDaemon() async throws -> AcpmuxEnvironment {
        guard let environment = await environment() else { throw PageError(code: "cmux.page.unavailable", message: "no acpmux") }
        return environment
    }

    /// A call that answers `ConnectionsState`: the page shows it at once.
    func mutate(_ method: AcpmuxHarnessMethod, _ params: [String: any Sendable]) async throws {
        let reply = try JSONValue.parse(try await daemon(try requireDaemon(), method, params))
        generation += 1
        if reply["connections"] != nil { apply(reply, preserveNativeSignIns: true) } else { await refresh() }
        if let reference = reply["replaced_secret"]?.stringValue { await deleteKey(reference) }
    }

    private func push(spread on: Bool, _ environment: AcpmuxEnvironment) async throws {
        let reply = try JSONValue.parse(try await daemon(environment, .connectionsSpreadSet, ["on": on]))
        if reply["connections"] != nil { apply(reply, preserveNativeSignIns: true) } else { daemonSpread = on }
    }

    /// The app's mirror of `models.spreadUsage` (every writer): acpmux's copy follows, best effort (a
    /// daemon not up yet gets it at the card's next read, which compares the two).
    public nonisolated static func pushSpread(_ on: Bool, environment: AcpmuxEnvironment) async {
        _ = try? await environment.harness(.connectionsSpreadSet, params: ["on": on])
    }

    /// One daemon call: the test's stand-in, else the local socket.
    func daemon(_ environment: AcpmuxEnvironment, _ method: AcpmuxHarnessMethod, _ params: [String: any Sendable],
                rollbackKeychainReference: String? = nil) async throws -> Data {
        do {
            if let call { return try await call(environment, method, params) }
            return try await environment.harness(method, params: params)
        } catch let error as AcpmuxRPCError {
            if let rollbackKeychainReference, let code = error.code, code != -32603, !error.isUnreachable {
                await deleteKey(rollbackKeychainReference)
            }
            throw PageError(code: "cmux.models.\(error.name ?? (error.isMethodMissing ? "unsupported" : "failed"))", message: error.message)
        }
    }

    nonisolated static func pageError(_ error: any Error) -> PageError {
        if let error = error as? PageError { return error }
        if case .refused(let code)? = error as? TeamAgentKeys.Failure { return PageError(code: "cmux.models.\(code)", message: code) }
        return PageError(code: "cmux.models.failed", message: "the change could not be made")
    }
}
