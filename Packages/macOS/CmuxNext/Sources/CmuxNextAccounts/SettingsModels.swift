public import CmuxNextAgentPane
import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation
import Observation

/// Settings > Models (cmux-tui/docs/model-connections.md): the person's model connections from acpmux
/// (`_acpmux/connections`), the team's shared keys and the team's members policy, for
/// the React Settings page's `cmux.settings.models.state|run` and its `.changed` stream.
///
/// Every run maps to one owner: acpmux for the person's connections (order, spread, enable, remove,
/// Sign in with ChatGPT, an API key, a Claude setup token), the existing Claude account sign-in and a
/// terminal tab running `claude setup-token` (``SettingsHarnesses``), the owner API for the team's keys
/// (``TeamAgentKeys``) and policy (``TeamModelsPolicy``). Revision 2: no team gateway.
///
/// A pasted API key or setup token goes into this Mac's Keychain (``ModelKeyStoring``) before anything
/// else sees it; acpmux gets only its `keychain:ITEM` reference. It never reaches page state, a log or a file.
/// Spread lives in the settings schema (`models.spreadUsage`, so the palette, `cmux settings` and MCP
/// reach it); this mirrors it into acpmux, which keeps a copy in its bindings.
@MainActor
@Observable
public final class SettingsModels {
    /// acpmux's connection kinds and providers the page draws (`ModelConnection`).
    nonisolated static let kinds: Set<String> = ["codex-login", "claude-login", "subscription", "chatgpt-plan", "claude-token", "api-key"]
    nonisolated static let providers: Set<String> = ["openai", "anthropic", "openrouter", "google", "xai"]
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
    private(set) var read = false
    private(set) var chatgptAttempt: String?
    private(set) var chatgptError: String?

    @ObservationIgnored let environment: @MainActor () -> AcpmuxEnvironment?
    @ObservationIgnored private let call: (@Sendable (AcpmuxEnvironment, AcpmuxHarnessMethod, [String: any Sendable]) async throws -> Data)?
    @ObservationIgnored private let keys: any ModelKeyStoring
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let harnesses: SettingsHarnesses?
    @ObservationIgnored private let team: @MainActor () -> (id: String, name: String)?
    @ObservationIgnored private let agentKeys: TeamAgentKeys?
    @ObservationIgnored private let policy: TeamModelsPolicy?
    @ObservationIgnored private let spreadSetting: (@MainActor () -> Bool)?
    @ObservationIgnored private let writeSpreadSetting: (@MainActor (Bool) async throws -> Void)?
    @ObservationIgnored private var generation = 0
    /// Called each time this Mac's connections are read or change (a run's answer, a watched change): a
    /// Cloud chat waiting on Set up Cloud checks again (``CloudSetup/connectionsChanged()``, set by the app).
    @ObservationIgnored public var onConnections: (@MainActor () -> Void)?
    @ObservationIgnored private(set) var chatgptTask: Task<Void, Never>?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0

    /// - Parameters:
    ///   - call: a test's stand-in for the daemon; nil calls it (``AcpmuxEnvironment/harness(_:params:)``).
    ///   - openURL: opens the ChatGPT sign-in page in the person's browser, in the background.
    ///   - team: the active team's id and name; nil signed out or for the personal team.
    ///   - spreadSetting, writeSpreadSetting: `models.spreadUsage`, read and written through the settings writer.
    public init(environment: @escaping @MainActor () -> AcpmuxEnvironment?,
                call: (@Sendable (AcpmuxEnvironment, AcpmuxHarnessMethod, [String: any Sendable]) async throws -> Data)? = nil,
                keys: any ModelKeyStoring,
                openURL: @escaping @MainActor (URL) -> Void,
                harnesses: SettingsHarnesses? = nil,
                team: @escaping @MainActor () -> (id: String, name: String)? = { nil },
                agentKeys: TeamAgentKeys? = nil,
                policy: TeamModelsPolicy? = nil,
                spreadSetting: (@MainActor () -> Bool)? = nil,
                writeSpreadSetting: (@MainActor (Bool) async throws -> Void)? = nil) {
        self.environment = environment
        self.call = call
        self.keys = keys
        self.openURL = openURL
        self.harnesses = harnesses
        self.team = team
        self.agentKeys = agentKeys
        self.policy = policy
        self.spreadSetting = spreadSetting
        self.writeSpreadSetting = writeSpreadSetting
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
        return [
            "personal": ["connections": .array(connections), "spread": .bool(spread), "available": .bool(available)],
            "organization": [
                "team": active.map { team -> JSONValue in ["id": .string(team.id), "name": .string(team.name)] } ?? .null,
                "canEdit": .bool(active != nil && agentKeys?.canManage == true),
                "keys": .array(keys),
            ],
            "members": members,
            "chatgpt": ["attempt": chatgptAttempt.map(JSONValue.string) ?? .null, "error": chatgptError.map(JSONValue.string) ?? .null],
        ]
    }

    /// The switch the page shows: the setting (the one writer) when there is one, else acpmux's copy.
    var spread: Bool { spreadSetting?() ?? daemonSpread }

    /// The state after the first read (the page's first `state` call reads it).
    public func loadedState() async -> JSONValue {
        if !read || !available { await refresh() } // not listed yet (acpmux still coming up): the page's next read asks again
        return state
    }

    /// Reads acpmux's connections, the team's keys and policy again. Only the newest read writes.
    public func refresh() async {
        generation += 1
        let mine = generation
        read = true
        async let teamRead: Void = refreshTeam()
        if let environment = environment() {
            do {
                let reply = try JSONValue.parse(try await daemon(environment, .connections, [:]))
                if mine == generation { apply(reply) }
                startWatch()
                // The setting is the writer: an acpmux copy that differs (another client, an older run) follows it.
                if mine == generation, let wanted = spreadSetting?(), wanted != daemonSpread {
                    try? await push(spread: wanted, environment)
                }
            } catch {
                if mine == generation { available = false }
            }
        } else {
            available = false
            connections = []
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
    func apply(_ reply: JSONValue) {
        connections = (reply["connections"]?.arrayValue ?? []).compactMap(Self.connection)
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
        let provider = value["provider"]?.stringValue.flatMap { providers.contains($0) ? $0 : nil }
            ?? (kind == "claude-login" || kind == "claude-token" ? "anthropic" : "openai")
        return [
            "id": .string(id), "kind": .string(kind), "provider": .string(provider),
            "families": strings("families", "families"), "label": .string(value["label"]?.stringValue ?? id),
            "email": text("email"), "plan": text("plan"),
            "signedIn": .bool(value["signed_in"]?.boolValue ?? value["signedIn"]?.boolValue ?? false),
            "enabled": .bool(value["enabled"]?.boolValue ?? false),
            "defaultFor": strings("default_for", "defaultFor"),
            "servesCloud": .bool(value["serves_cloud"]?.boolValue ?? value["servesCloud"]?.boolValue ?? false),
        ]
    }

    // MARK: Watching

    /// The page shows the card: each `_acpmux/connections.changed` carries acpmux's whole
    /// `ConnectionsState`, which shows at once (a note without one reads the state again).
    public func beginWatching() {
        watchers += 1
        startWatch()
    }

    /// The watch, once a page shows the card and acpmux is up (a daemon that comes up later starts it
    /// at the card's next read).
    private func startWatch() {
        guard watchers > 0, watch == nil, let environment = environment() else { return }
        let (changes, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
        let socket = environment.watchConnections { continuation.yield($0) }
        // task-owner: SettingsModels.watch: one update per acpmux change while a page shows the card; endWatching cancels it.
        watch = Task { [weak self] in
            await withTaskCancellationHandler {
                for await line in changes { await self?.changed(line) }
            } onCancel: {
                socket.cancel()
                continuation.finish()
            }
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
        watch?.cancel()
        watch = nil
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
            let environment = try requireDaemon()
            try await push(spread: on, environment)
        case "enable":
            guard let id = listedID(params), let on = params["on"]?.boolValue else { throw PageError.invalidParams("enable needs a listed id and on") }
            _ = try await daemon(try requireDaemon(), .accountSet, ["id": id, "enabled": on])
            await refresh()
        case "remove":
            guard let id = listedID(params) else { throw PageError.invalidParams("remove needs a listed id") }
            try await remove(id)
        case "connectChatGPT":
            return try await connectChatGPT(id: params["id"]?.stringValue)
        case "cancelChatGPT":
            await cancelChatGPT()
        case "connectClaude":
            guard let harnesses else { throw PageError.unavailable("Claude sign-in is not available here") }
            try await harnesses.connectClaude(context: context)
        case "claudeSetupToken":
            // The person's own gesture: a new terminal tab in their window runs Claude Code's `claude setup-token`.
            guard let harnesses else { throw PageError.unavailable("no terminal tab could be opened on this Mac") }
            try await harnesses.typeLine("claude setup-token")
        case "addClaudeToken":
            try await addClaudeToken(params["token"]?.stringValue ?? "", label: params["label"]?.stringValue)
        case "addKey":
            try await addKey(provider: params["provider"]?.stringValue ?? "", key: params["key"]?.stringValue ?? "",
                             label: params["label"]?.stringValue)
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

    /// Removes a connection. A key or setup token cmux stored (`keychain:cmux-model-key/...`, read from
    /// its route before the removal) leaves the Keychain once acpmux confirms; a reference cmux did not
    /// create stays.
    private func remove(_ id: String) async throws {
        let environment = try requireDaemon()
        let kind = connections.first { $0["id"]?.stringValue == id }?["kind"]?.stringValue
        var reference: String?
        if kind == "api-key" || kind == "claude-token" {
            let route = try? JSONValue.parse(try await daemon(environment, .routeShow, ["id": id]))
            reference = route?["secret"]?.stringValue.flatMap { $0.hasPrefix(Self.ownedReference) ? $0 : nil }
        }
        try await mutate(.connectionsRemove, ["id": id])
        if let reference { await keys.delete(reference) }
    }

    /// The `keychain:` references cmux's own key store makes (``KeychainModelKeyStore``).
    nonisolated static let ownedReference = "keychain:\(KeychainModelKeyStore.service)/"

    /// A connection id the last read listed.
    private func listedID(_ params: JSONValue) -> String? {
        guard let id = params["id"]?.stringValue, connections.contains(where: { $0["id"]?.stringValue == id }) else { return nil }
        return id
    }

    func requireDaemonEnvironment() throws -> AcpmuxEnvironment { try requireDaemon() }

    // The +Live extension's reach into this object's state (its own file cannot see the private members).
    func setChatGPT(attempt: String?, error: String?) {
        chatgptAttempt = attempt
        chatgptError = error
    }

    func openSignIn(_ url: URL) { openURL(url) }

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

    private func requireDaemon() throws -> AcpmuxEnvironment {
        guard let environment = environment() else { throw PageError(code: "cmux.page.unavailable", message: "no acpmux") }
        return environment
    }

    /// A call that answers `ConnectionsState`: the page shows it at once.
    private func mutate(_ method: AcpmuxHarnessMethod, _ params: [String: any Sendable]) async throws {
        let reply = try JSONValue.parse(try await daemon(try requireDaemon(), method, params))
        generation += 1
        if reply["connections"] != nil { apply(reply) } else { await refresh() }
    }

    private func push(spread on: Bool, _ environment: AcpmuxEnvironment) async throws {
        let reply = try JSONValue.parse(try await daemon(environment, .connectionsSpreadSet, ["on": on]))
        if reply["connections"] != nil { apply(reply) } else { daemonSpread = on }
    }

    /// The app's mirror of `models.spreadUsage` (every writer): acpmux's copy follows, best effort (a
    /// daemon not up yet gets it at the card's next read, which compares the two).
    public nonisolated static func pushSpread(_ on: Bool, environment: AcpmuxEnvironment) async {
        _ = try? await environment.harness(.connectionsSpreadSet, params: ["on": on])
    }

    /// One daemon call: the test's stand-in, else the local socket.
    func daemon(_ environment: AcpmuxEnvironment, _ method: AcpmuxHarnessMethod, _ params: [String: any Sendable]) async throws -> Data {
        do {
            if let call { return try await call(environment, method, params) }
            return try await environment.harness(method, params: params)
        } catch let error as AcpmuxRPCError {
            throw PageError(code: "cmux.models.\(error.name ?? (error.isMethodMissing ? "unsupported" : "failed"))", message: error.message)
        }
    }

    nonisolated static func pageError(_ error: any Error) -> PageError {
        if let error = error as? PageError { return error }
        if case .refused(let code)? = error as? TeamAgentKeys.Failure { return PageError(code: "cmux.models.\(code)", message: code) }
        return PageError(code: "cmux.models.failed", message: "the change could not be made")
    }
}
