public import CmuxNextDaemon
public import Foundation
import os

/// Cloud first use (cmux-tui/docs/model-connections.md, "Cloud first use" and Revision 2): before a
/// Cloud chat starts, which connection serves the model the picker chose (``choose(harness:model:account:)``).
/// A personal one (`_acpmux/connections` on this Mac, served straight to the machine) or the
/// organization's shared key serving the picker's family starts the chat with no prompt; none shows
/// the chat's Set up Cloud card, which starts the chat by itself once one appears (``waitUntilServed(family:)``).
/// With none of those, a team in inference gateway mode whose gateway is online (``gateway``) serves the chat too.
///
/// What it reads and how it connects are seams the App fills (``read``, ``run``): the Settings > Cloud >
/// Cloud models ops own the connections; this holds only the rule and the wait. Every change to the
/// connections (an op that finished, `cmux.settings.models.changed`, acpmux's
/// `_acpmux/connections.changed`) calls ``connectionsChanged()``.
@MainActor
public final class CloudSetup {
    /// One connection as `_acpmux/connections` lists it (`Connection`), the fields the rule reads, in
    /// the order the daemon lists them.
    public struct Connection: Sendable, Equatable {
        public var id: String
        public var families: [String]
        public var signedIn: Bool
        public var enabled: Bool
        public var servesCloud: Bool
        public var canServeCloud: Bool
        public var endpointProfile: Bool
        public var endpointCredentials: Bool
        public var launchHarness: String?
        public var subscriptionCredentials: Bool
        public var kind: String?
        package var credentialInstance: String?

        public init(id: String, families: [String], signedIn: Bool = true, enabled: Bool = true, servesCloud: Bool = true, canServeCloud: Bool? = nil,
                    endpointProfile: Bool = false, endpointCredentials: Bool = false, launchHarness: String? = nil, subscriptionCredentials: Bool = false, kind: String? = nil, credentialInstance: String? = nil) {
            (self.id, self.families, self.signedIn, self.enabled, self.servesCloud) = (id, families, signedIn, enabled, servesCloud)
            self.canServeCloud = canServeCloud ?? servesCloud
            (self.endpointProfile, self.endpointCredentials) = (endpointProfile, endpointCredentials)
            self.launchHarness = launchHarness
            self.subscriptionCredentials = subscriptionCredentials
            self.kind = kind
            self.credentialInstance = credentialInstance
        }

        /// A `Connection` object of `_acpmux/connections`; nil for anything without an id.
        public init?(json: [String: Any]) {
            guard let id = json["id"] as? String, !id.isEmpty else { return nil }
            let endpoint = json["kind"] as? String == "endpoint"
            let localOnly = endpoint || json["provider"] as? String == "openrouter"
            self.init(id: id, families: json["cloud_families"] as? [String] ?? json["families"] as? [String] ?? [],
                      signedIn: json["signed_in"] as? Bool ?? true, enabled: json["enabled"] as? Bool ?? true,
                      servesCloud: !localOnly && (json["serves_cloud"] as? Bool ?? true),
                      canServeCloud: localOnly ? false : json["can_serve_cloud"] as? Bool,
                      endpointProfile: endpoint,
                      endpointCredentials: json["endpoint_credentials"] as? Bool == true, launchHarness: json["launch_harness"] as? String,
                      subscriptionCredentials: ["grok-plan", "copilot-plan"].contains(json["kind"] as? String ?? ""),
                      kind: json["kind"] as? String, credentialInstance: json["credential_instance"] as? String)
        }
    }

    /// Why a family with a known readiness answer has no usable Cloud connection.
    public enum ConnectionReason: String, Sendable {
        case none, signedOut, off, cloudOff
    }

    /// Picker readiness, including reasons only for families known to be disconnected.
    public struct Readiness: Sendable {
        public var families: [String: Bool]
        public var reasons: [String: ConnectionReason]
        public var servedHarnesses: [String]
        public var pendingHarnesses: [String]
        public var unavailableEndpointHarnesses: [String]
        public var environmentMatches: Bool?

        public init(families: [String: Bool] = [:], reasons: [String: ConnectionReason] = [:], servedHarnesses: [String] = [], pendingHarnesses: [String] = [], unavailableEndpointHarnesses: [String] = []) {
            (self.families, self.reasons) = (families, reasons)
            (self.servedHarnesses, self.pendingHarnesses, self.unavailableEndpointHarnesses) = (servedHarnesses, pendingHarnesses, unavailableEndpointHarnesses)
        }
    }

    /// What serves Cloud now. `personal` nil: this Mac's connections could not be read (no daemon,
    /// an acpmux before `_acpmux/connections`); `organization` nil: the team's could not be read.
    public struct Snapshot: Sendable, Equatable {
        public var personal: [Connection]?
        /// The families the organization serves: the agents of its shared keys that are set.
        public var organization: Set<String>?

        public init(personal: [Connection]?, organization: Set<String>?) {
            (self.personal, self.organization) = (personal, organization)
        }

        /// The organization's families from its shared keys (`team.agent_key.status` rows).
        public static func organization(keys: [(agent: String, set: Bool)]) -> Set<String> {
            Set(keys.filter(\.set).map(\.agent))
        }

        /// The connection a Cloud chat on `family` uses (Revision 2): the picker's `account` when it
        /// serves Cloud for that family. An explicitly selected connection with Cloud use off
        /// refuses the start. Otherwise use the first enabled Cloud-serving connection in the
        /// daemon's order, then the organization's shared key. When this Mac's connections
        /// are unread and there is no shared key, ``Choice/fallback`` represents unknown readiness.
        public func choice(family: String, model: String?, account: String?) -> Choice {
            if let personal {
                if let account,
                   personal.contains(where: { $0.id == account && $0.canServeCloud && !$0.servesCloud && $0.families.contains(family) }) {
                    return .localOnly
                }
                let serving = personal.filter { $0.enabled && $0.signedIn && $0.servesCloud && $0.families.contains(family) }
                if let pick = serving.first(where: { $0.id == account }) ?? serving.first {
                    return .connection(id: pick.id, family: family, credentialInstance: pick.credentialInstance)
                }
            }
            if organization?.contains(family) == true { return .organization(family: family) }
            return personal == nil ? .fallback : .setup(family: family, model: model)
        }

        /// Whether a connection serves `family`; nil when this Mac's connections were not read.
        public func serves(_ family: String) -> Bool? {
            switch choice(family: family, model: nil, account: nil) {
            case .connection, .organization, .gateway, .claudeMachineLogin: true
            case .setup, .localOnly: false
            case .fallback: nil
            }
        }

        fileprivate func connectionReason(for family: String) -> ConnectionReason {
            let matching = personal?.filter { $0.families.contains(family) } ?? []
            if matching.contains(where: { $0.canServeCloud && !$0.servesCloud && $0.enabled && $0.signedIn }) { return .cloudOff }
            if matching.contains(where: { $0.servesCloud && $0.enabled && !$0.signedIn }) { return .signedOut }
            if matching.contains(where: { $0.servesCloud && !$0.enabled }) { return .off }
            return .none
        }
    }

    /// The connection one Cloud start runs on (``choose(harness:model:account:)``).
    public enum Choice: Equatable, Sendable {
        /// The saved connection selected from this Mac's daemon, including its instance at selection time.
        case connection(id: String, family: String, credentialInstance: String? = nil)
        /// The organization's shared key for `family`, which the platform edge serves; nothing to send.
        case organization(family: String)
        /// The inference gateway of the team the machine is made in, in gateway mode and online, serves `family` (``gateway``): the machine's
        /// agent reaches it through the edge, so nothing is sent (hq#15762).
        case gateway(family: String)
        /// The selected owner machine has its own Claude sign-in.
        case claudeMachineLogin
        /// Nothing serves `family`: the chat shows Set up Cloud naming `model`, and nothing starts.
        case setup(family: String, model: String?)
        /// The selected account or profile is limited to this Mac.
        case localOnly
        /// The snapshot has unknown readiness.
        case fallback

        /// The guest authentication source selected by readiness for Claude.
        public var claudeAuth: AgentSessionAttachClient.ClaudeAuth? {
            switch self {
            case .claudeMachineLogin: .own
            case .gateway(let family), .organization(let family): family == "claude" ? .team : nil
            default: nil
            }
        }

        /// This Mac's connection whose credential the chat's agent launch carries; nil for every other choice.
        public var connectionID: String? {
            if case .connection(let id, _, _) = self { return id }
            return nil
        }

        var requiresCredentialInstance: Bool {
            guard case .connection(_, let family, let instance) = self else { return false }
            return instance != nil || CloudSetup.nativeHarnesses[family] != nil
        }

        /// Whether the chat's model calls go somewhere other than this Mac's own gateway (``PersonalGateway``): the
        /// agent launch carries this Mac's connection credential, or the platform edge serves the organization's key.
        /// A start then has no gateway to wait for before its first turn. The production probe's starts on such a
        /// route waited out the gateway's whole 10 s deadline in about one in five runs (2026-11-21).
        public var servedWithoutMacGateway: Bool {
            switch self {
            case .connection, .organization, .claudeMachineLogin: true
            case .gateway, .setup, .localOnly, .fallback: false
            }
        }
    }

    /// The families a Cloud chat runs (the picker's agent, as the gateway names them).
    public nonisolated static let families = ["claude", "codex"]

    public nonisolated static let setupFamilies = families + nativeHarnesses.keys.sorted()

    private nonisolated static let nativeHarnesses = ["gemini": "gemini", "grok": "grok"]
    private nonisolated static let localOnlyPlanKinds: Set<String> = ["grok-plan", "copilot-plan", "kimi-plan"]

    /// The gateway family of the picker's Claude or Codex profile.
    public nonisolated static func family(of harness: String?) -> String? {
        let name = (harness ?? "claude").lowercased()
        return families.first { name == $0 || name.hasPrefix($0 + "-") || name.hasPrefix($0 + ":") }
    }

    /// The decision for one start.
    public enum Decision: Equatable, Sendable {
        /// A connection serves the picker's model.
        case start
        /// Nothing serves `family`: the chat shows Set up Cloud naming `model`.
        case setup(family: String, model: String?)
    }

    /// The setup actions accepted by `cloud.setUp`. Each opens its family in Settings > Cloud > Cloud models.
    public enum Action: String, Sendable, CaseIterable {
        case connectChatGPT, setUpClaude, addKey, openSettings

        /// Legacy row identifiers understood by existing Settings links.
        public var settingsRow: String? {
            switch self {
            case .connectChatGPT: "cloud.chatgpt"
            case .setUpClaude: "cloud.claude"
            case .addKey: "cloud.apiKey"
            case .openSettings: nil
            }
        }
    }

    /// Whether `value` can name a connection (an `_acpmux/connections` id, the picker's account).
    public nonisolated static func isConnectionID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || ".-_:@".utf8.contains(byte)
        }
    }

    /// Cloud setup also accepts named harness profiles such as `providers/deepseek`.
    public nonisolated static func isSetupFamily(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count)
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { isConnectionID(String($0)) }
    }

    /// Reads what serves Cloud now.
    public var read: (@MainActor () async -> Snapshot)?
    /// The families the inference gateway of the team the start's machines are made in (the install's own) serves now (`cmux inference gateway status`'s `serves`), nil
    /// when unread. Read only when nothing else serves the chat, so a start that has a connection pays nothing for it.
    public var gateway: (@MainActor () async -> Set<String>?)?
    /// The last read behind ``gateway``: the team it asked and the CLI's error code when it could not be read. A refusal
    /// carries it (``Refusal/gateway``), so a refused start says which team's gateway it read and why it counted none (hq#19758).
    public var gatewayRead: GatewayRead?

    /// One `cmux inference gateway status --team` read (``CloudMoveCLI/inferenceGatewayStatus(team:held:)``).
    public struct GatewayRead: Equatable, Sendable {
        /// The CLI ran past its bound (the read's 10 s).
        public static let timedOut = "timed_out"
        /// No install token, so no team to read.
        public static let noInstallToken = "no_install_token"
        public var team: String?
        /// The agents it serves now; nil when unread.
        public var serves: Set<String>?
        /// Why it is unread: the CLI's `error.code` (`auth.no_token`, `api.unreachable`, ...), ``timedOut`` or ``noInstallToken``.
        public var errorCode: String?

        public init(team: String?, serves: Set<String>? = nil, errorCode: String? = nil) {
            (self.team, self.serves, self.errorCode) = (team, serves, errorCode)
        }

        /// The gate's reads, each team once: the install team with the install token the app holds, so the CLI mints none
        /// (hq#19758), then the person's own team through the CLI's own mint (#51322), a read the caller started beside the
        /// token's bind wait (cmux#55519) and this cancels when it names the install team. `install` is the read a refusal
        /// carries (``noInstallToken`` with no token); each unread answer logs why.
        public static func serves(cli: CloudMoveCLI, install: (team: String, token: String)?, personal: (team: String, read: Task<GatewayRead, Never>)?, apiOrigin: URL) async -> (serves: Set<String>?, install: GatewayRead) {
            let log = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud") // the app's cloud log, where the gate's other lines go
            var installRead = GatewayRead(team: nil, errorCode: noInstallToken), reads: [(String, GatewayRead)] = []
            if let install {
                installRead = await cli.inferenceGatewayStatus(team: install.team, held: (install.token, apiOrigin))
                reads.append((install.team, installRead))
            }
            if let personal {
                if personal.team == install?.team { personal.read.cancel() } else { reads.append((personal.team, await personal.read.value)) }
            }
            var serves: Set<String>?
            for (team, read) in reads {
                if let answer = read.serves {
                    log.info("cloud start gate: team \(team, privacy: .public) gateway serves [\(answer.sorted().joined(separator: ","), privacy: .public)]")
                    serves = (serves ?? []).union(answer)
                } else {
                    log.error("cloud start gate: team \(team, privacy: .public) gateway unread: \(read.errorCode ?? "-", privacy: .public)")
                }
            }
            if reads.isEmpty { log.error("cloud start gate: gateway unread: no team to ask") }
            return (serves, installRead)
        }
    }

    /// Opens Settings > Cloud > Cloud models for the card's action and family while the send waits.
    public var run: (@MainActor (Action, String, String?) async -> Void)?
    /// Starts an unscoped connection from the setup card. False keeps the Settings path available.
    public var connectInPlace: (@MainActor (Action) async -> Bool)?
    /// Validates an explicit destination against the current Cloud account.
    public var ownsMachine: (@MainActor (String) -> Bool)?
    public var accountScope: (@MainActor () -> [String?])?
    /// Reads confirmed endpoint harnesses on a machine named by the picker.
    public var machineHarnesses: (@MainActor (String) -> Set<String>?)?
    /// Reads confirmed runners that accept subscription credentials.
    public var machineSubscriptionHarnesses: (@MainActor (String) -> Set<String>?)?
    public var claudeMachines: (@MainActor () -> [CloudMachine])?
    public var loadCloudMachines: (@MainActor () async -> Void)?
    public var readClaudeMachineLogin: (@MainActor (String) async -> Bool)?

    /// Live owner-only status for the machine the app or CLI is about to use.
    public func readyClaudeMachines(machine: String? = nil, environment: String? = nil, name: String? = nil) async -> [String] {
        guard let readClaudeMachineLogin else { return [] }
        let scope = accountScope?()
        await loadCloudMachines?()
        guard !Task.isCancelled, scope == accountScope?() else { return [] }
        let candidates = (claudeMachines?() ?? []).filter {
            (machine == nil || $0.id == machine)
                && CloudStartCore().matchesEnvironment(environment, machine: $0)
                && (name == nil || $0.title == name)
                && [.running, .provisioning, .starting, .unknown].contains($0.shownStatus)
        }.map(\.id).sorted()
        var ready: [String] = []
        for id in candidates {
            if await readClaudeMachineLogin(id) { ready.append(id) }
            guard !Task.isCancelled, scope == accountScope?() else { return [] }
        }
        return ready
    }
    /// Retains environment provenance when the platform's ordinary machine list omits it.
    public func machineEnvironment(_ record: CloudMachine, ensured: String? = nil, account: [String?], defaults: UserDefaults?) -> CloudMachine {
        let key = "cloudMachineEnvironment." + CloudStartCore().accountText(account) + "." + record.id
        var record = record
        let derivedKey = key + ".derived"
        let saved = defaults?.string(forKey: key), derived = defaults?.string(forKey: derivedKey)
        if let actual = record.environmentId {
            if let ensured, ensured.hasPrefix("env_"), actual.hasPrefix("denv_") {
                if actual != derived { defaults?.set(actual, forKey: derivedKey) }
                record.environmentId = ensured
            } else if actual == derived {
                record.environmentId = saved ?? actual
            } else if derived != nil, actual != saved {
                defaults?.removeObject(forKey: derivedKey)
            }
        } else {
            if let ensured, ensured != saved, derived != nil { defaults?.removeObject(forKey: derivedKey) }
            record.environmentId = ensured ?? saved
        }
        if let environment = record.environmentId, environment != saved { defaults?.set(environment, forKey: key) }
        return record
    }

    public func claudeMachine(named name: String) -> String? {
        claudeMachines?().first { $0.title == name }?.id
    }

    public func machineMatchesEnvironment(_ machine: String, environment: String) -> Bool {
        claudeMachines?().contains { $0.id == machine && CloudStartCore().matchesEnvironment(environment, machine: $0) } == true
    }

    /// Opens Settings > Cloud > Cloud models for the family selected in the picker.
    public var openConnectionSettings: (@MainActor (String, String?, Bool, String?, String?) -> Void)?

    /// One wait's wake: fired once, by a change or by its task's cancel, whichever comes first.
    private final class Wake: Sendable {
        private let state = OSAllocatedUnfairLock<(continuation: CheckedContinuation<Void, Never>?, fired: Bool)>(initialState: (nil, false))

        func hold(_ continuation: CheckedContinuation<Void, Never>) {
            let now = state.withLock { state in
                if state.fired { return true }
                state.continuation = continuation
                return false
            }
            if now { continuation.resume() }
        }

        func fire() {
            let continuation = state.withLock { state in
                state.fired = true
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume()
        }
    }

    public struct SetupCompletion: Sendable, Equatable {
        public let machine: String?
        public let usesMachineLogin: Bool
        public let environment: String?
        public let bindsEnvironment: Bool

        public init(machine: String? = nil, usesMachineLogin: Bool = false, environment: String? = nil, bindsEnvironment: Bool = false) {
            self.machine = machine
            self.usesMachineLogin = usesMachineLogin
            self.environment = environment
            self.bindsEnvironment = bindsEnvironment
        }
    }

    private final class ClaudeSetupWait {
        let machine: String?
        let account: [String?]?
        let environment: String?
        var signedInMachine: String?

        init(machine: String?, account: [String?]?, environment: String?) {
            self.machine = machine
            self.account = account
            self.environment = environment
        }
    }

    private var claudeSetups: [UUID: ClaudeSetupWait] = [:]
    private var waiters: [UUID: Wake] = [:]
    /// Bumped by every ``connectionsChanged()``: a wait whose read began before one reads again.
    private var changes = 0

    public init(read: (@MainActor () async -> Snapshot)? = nil, run: (@MainActor (Action, String, String?) async -> Void)? = nil) {
        (self.read, self.run) = (read, run)
    }

    /// The connection a Cloud start on the picker's `harness`, `model` and `account` runs on. Lane F
    /// (app-to-machine credential delivery) reads the chosen connection's credential and
    /// sends it with the agent launch; ``Choice/setup(family:model:)`` shows the card instead.
    public func choose(harness: String?, model: String?, account: String?) async -> Choice {
        await launchReadiness(harness: harness, model: model, account: account).choice
    }

    /// Selects the credential used by a Cloud launch and supplies the setup refusal when needed.
    public func launchReadiness(harness: String?, model: String?, account: String? = nil, readyClaude: Bool = false) async -> (choice: Choice, refusal: Refusal?) {
        let snapshot = routed(await read?() ?? .init(personal: nil, organization: nil))
        let normalized = (harness ?? "claude").lowercased()
        if normalized == "openrouter" || snapshot.personal?.contains(where: { $0.endpointProfile && $0.id == harness }) == true {
            return (.localOnly, nil)
        }
        let gatewayFamily = Self.family(of: harness)
        guard let family = gatewayFamily ?? (Self.nativeHarnesses[normalized] == nil ? nil : normalized)
        else { return (.fallback, nil) }
        let choice = snapshot.choice(family: family, model: model, account: account)
        switch choice {
        case .setup, .fallback:
            if (choice != .fallback || family == "claude" && readyClaude), await gatewayServes(family) {
                return (.gateway(family: family), nil)
            }
            if family == "claude", readyClaude { return (.claudeMachineLogin, nil) }
        default:
            break
        }
        guard case .setup(_, let model) = choice, gatewayFamily != nil else { return (choice, nil) }
        let local = snapshot.personal?.contains { $0.enabled && $0.signedIn && !$0.servesCloud && $0.families.contains(family) } == true
        return (choice, Refusal(family: family, model: model, localLogin: local, gateway: gatewayRead))
    }

    /// A team key can be advertised before the selected guest can route to it.
    /// Retry the same start only after the guest refuses that route and confirms its own login.
    package static func startWithClaudeFallback(
        _ choice: AgentSessionAttachClient.ClaudeAuth?, isSignedIn: @MainActor () async -> Bool,
        start: @MainActor (AgentSessionAttachClient.ClaudeAuth?) async throws -> String
    ) async throws -> String {
        do {
            return try await start(choice)
        } catch let error as AgentSessionAttachError
            where choice == .team && error.code == "agent_session.route_unavailable"
                && error.details?["reason"]?.stringValue == "route.unavailable" {
            guard await isSignedIn() else { throw error }
            try Task.checkCancellation()
            return try await start(.own)
        }
    }

    /// The credential requirements of the chosen connection.
    public func launchConnection(_ connection: String?) async -> Connection? {
        guard let connection, let read else { return nil }
        let snapshot = routed(await read())
        return snapshot.personal?.first(where: { $0.id == connection })
    }

    /// Whether the gateway of the team the machine is made in serves `family` now (``gateway``); false when it is unread, or when a start on it
    /// found no model route within ``gatewayUnroutedHold`` (``unrouted(harness:model:account:)``).
    private func gatewayServes(_ family: String) async -> Bool {
        gatewayRead = nil // this read's own, never an earlier one's
        guard !unroutedGateway.contains(family) else { return false }
        return await gateway?()?.contains(family) == true
    }

    /// The families whose team gateway a start found unrouted within the last ``gatewayUnroutedHold``: until then Set up
    /// Cloud waits for a connection of the person's own instead of starting again on the same gateway. Unlike
    /// ``unroutedOrganization`` (the shared key has no route at all) a gateway that gave one machine no route is asked again
    /// after the hold: held for the whole app run, one machine that came up without a model route refused every later
    /// claude start in about 300 ms (start-matrix-production run 45857917362: 15 rows "No Cloud connection serves claude"
    /// after the big-folder row, while the gateway still served).
    public var unroutedGateway: Set<String> { Set(unroutedGatewayAt.filter { now().timeIntervalSince($0.value) < Self.gatewayUnroutedHold }.keys) }
    /// When a start last found each family's gateway unrouted.
    private var unroutedGatewayAt: [String: Date] = [:]
    /// How long a gateway that gave a machine no model route is skipped: long enough that the Set up Cloud card does not
    /// start again on it at once, short enough that the next start minutes later asks it again.
    public nonisolated static let gatewayUnroutedHold: TimeInterval = 120
    /// The clock ``unroutedGateway`` reads (tests move it).
    public var now: @Sendable () -> Date = { Date() }

    /// The families whose organization shared key a start found unrouted (``organizationUnrouted(_:)``).
    public private(set) var unroutedOrganization: Set<String> = []

    /// A start on the organization's shared key for `family` reached a machine with no model route: the key is served
    /// only through the Cloud service's edge, which gives machines none now (cmux-platform#1489). For the rest of this
    /// run a start no longer chooses that key, so Set up Cloud waits for a connection of the person's own
    /// (``waitUntilServed(family:)``) instead of starting again on the same key (cmux#45773).
    public func organizationUnrouted(_ family: String) {
        unroutedOrganization.insert(family)
        connectionsChanged()
    }

    /// A start on `harness`, `model` and `account` reached a machine whose agent reaches no model and carried no connection
    /// (`CloudMachineRoute.NeedsConnection`): when it ran on the organization's shared key or the team's gateway, that one is
    /// unrouted (``organizationUnrouted(_:)``, ``unroutedGateway``), and the answer is the Set up Cloud card's family and model where the next choice
    /// is that card. Nil for anything else (connections unread, an agent Cloud does not serve): the card could never pass.
    public func unrouted(harness: String?, model: String?, account: String?) async -> (family: String, model: String?)? {
        let family: String
        switch await choose(harness: harness, model: model, account: account) {
        case .organization(let chosen): family = chosen; organizationUnrouted(chosen)
        case .gateway(let chosen): family = chosen; unroutedGatewayAt[chosen] = now(); connectionsChanged()
        default: return nil
        }
        guard case .setup(_, let model) = await choose(harness: harness, model: model, account: account) else { return nil }
        return (family, model)
    }

    /// `snapshot` without the organization families a start found unrouted.
    private func routed(_ snapshot: Snapshot) -> Snapshot {
        var snapshot = snapshot
        snapshot.personal?.removeAll { $0.kind.map { Self.localOnlyPlanKinds.contains($0) } == true }
        snapshot.organization?.subtract(unroutedOrganization)
        return snapshot
    }

    /// Per family a Cloud chat runs (``families``), whether a connection serves it now, from the same read a start
    /// makes (``Snapshot/serves(_:)``, without unrouted organization keys). A family the read could not decide is
    /// left out: "not served" needs both this Mac's connections and the team's keys read (a team key read that was
    /// still loading must not show Connect for a family the team serves). With no reader the answer is empty, and
    /// the picker shows nothing (`cloud.setup.state`).
    public func served(machine: String? = nil, environment: String? = nil) async -> Readiness {
        var initial = Readiness()
        if let machine, let environment {
            await loadCloudMachines?()
            initial.environmentMatches = machineMatchesEnvironment(machine, environment: environment)
            if initial.environmentMatches == false { return initial }
        }
        guard let read else { return initial }
        let snapshot = routed(await read())
        let nativeClaude = snapshot.serves("claude") != true
            ? !(await readyClaudeMachines(machine: machine, environment: environment)).isEmpty : false
        let profiles = snapshot.personal?.filter(\.endpointProfile) ?? []
        let endpointRunners = machine.flatMap { machineHarnesses?($0) }
        let subscriptionRunners = machine.flatMap { machineSubscriptionHarnesses?($0) }
        func runners(for connection: Connection?) -> Set<String>? {
            connection?.subscriptionCredentials == true ? subscriptionRunners : endpointRunners
        }
        func chosenConnection(_ family: String) -> Connection? {
            guard let id = snapshot.choice(family: family, model: nil, account: nil).connectionID else { return nil }
            return snapshot.personal?.first { $0.id == id }
        }
        let configured = Self.nativeHarnesses.filter { snapshot.serves($0.key) == true }
            .flatMap { family, runner in
                let connection = chosenConnection(family)
                let confirmed = runners(for: connection)
                return ([family] + (connection.map { [$0.id] } ?? []))
                    .map { (id: $0, runner: runner, confirmed: confirmed) }
            }
        let served = Array(Set(configured.filter { $0.confirmed?.contains($0.runner) == true }.map(\.id))).sorted()
        let pending = Array(Set(configured.filter { $0.confirmed == nil }.map(\.id))).sorted()
        let unavailable = (profiles.map(\.id) + configured.map(\.id)).filter { !served.contains($0) && !pending.contains($0) }
        let gatewayCandidates = Self.families.filter { snapshot.serves($0) == false && !unroutedGateway.contains($0) }
        let gatewayFamilies = gatewayCandidates.isEmpty ? nil : await gateway?()
        initial.servedHarnesses = served
        initial.pendingHarnesses = pending
        initial.unavailableEndpointHarnesses = Array(Set(unavailable)).sorted()
        return (Self.families + Self.nativeHarnesses.keys.sorted()).reduce(into: initial) { state, family in
            let connection = chosenConnection(family)
            let confirmed = runners(for: connection)
            if let runner = Self.nativeHarnesses[family] {
                guard confirmed?.contains(runner) == true else { return }
                if let serves = snapshot.serves(family) {
                    state.families[family] = serves
                    if !serves { state.reasons[family] = snapshot.connectionReason(for: family) }
                }
                return
            }
            if let connection,
               connection.endpointCredentials, confirmed?.contains(connection.launchHarness ?? family) != true {
                if confirmed == nil { state.pendingHarnesses.append(family) }
                else { state.unavailableEndpointHarnesses.append(family) }
                return
            }
            if gatewayFamilies?.contains(family) == true && gatewayCandidates.contains(family) {
                state.families[family] = true
                return
            }
            if family == "claude", nativeClaude {
                state.families[family] = true
                return
            }
            guard let serves = snapshot.serves(family), serves || snapshot.organization != nil else { return }
            state.families[family] = serves
            if !serves { state.reasons[family] = snapshot.connectionReason(for: family) }
        }
    }

    /// The picker's Connect shows the family's Settings destination.
    public func connect(family: String, machine: String? = nil, environment: String? = nil, recoverySession: String? = nil) {
        openConnectionSettings?(family, machine, false, environment, recoverySession)
    }

    /// The decision for a start on `harness` and `model` (``choose(harness:model:account:)``).
    public func decide(harness: String?, model: String?) async -> Decision {
        guard let refused = await refusal(harness: harness, model: model) else { return .start }
        return .setup(family: refused.family, model: refused.model)
    }

    /// A start Set up Cloud holds back (``decide(harness:model:)``), with what its refusal names.
    public struct Refusal: Equatable, Sendable {
        public var family: String
        public var model: String?
        /// This Mac has a signed-in login of `family` that serves only this Mac (`serves_cloud: false`: the Claude
        /// Code or Codex CLI's own login), so the refusal says why that one does not count.
        public var localLogin: Bool
        /// The team gateway read the refusal counted (``gatewayRead``); nil when none was read.
        public var gateway: GatewayRead?
        /// The Settings > Cloud row that sets `family` up (``Action/settingsRow``).
        public var settingsRow: String { (family == "codex" ? Action.connectChatGPT : Action.setUpClaude).settingsRow ?? "" }
    }

    /// ``decide(harness:model:)``'s setup answer, from the same one read; nil when the start goes on (something serves it,
    /// or nothing could be read).
    public func refusal(harness: String?, model: String?, readyClaude: Bool = false) async -> Refusal? {
        await launchReadiness(harness: harness, model: model, readyClaude: readyClaude).refusal
    }

    /// Which families a Cloud chat can run now, for the composer's model picker with Cloud picked (`cloud.setupState`):
    /// true when a start would go on (``refusal(harness:model:)`` is nil), false when it would show Set up Cloud. Nil when
    /// nothing can be read, so the picker holds nothing back.
    public func serving() async -> [String: Bool]? {
        guard let read else { return nil }
        let snapshot = routed(await read()) // one read for both families
        var families: [String: Bool] = [:]
        for family in Self.families {
            if case .setup = snapshot.choice(family: family, model: nil, account: nil) { families[family] = await gatewayServes(family) } else { families[family] = true }
        }
        return families
    }

    /// The connections changed: every wait checks again.
    public func connectionsChanged() {
        changes += 1
        let woken = waiters
        waiters = [:]
        for wake in woken.values { wake.fire() }
    }

    /// A machine login completed while Settings was open for a held Cloud send.
    public func claudeSignInCompleted(machine: String) {
        let account = accountScope?()
        let environment = claudeMachines?().first { $0.id == machine }?.environmentId
        for wait in claudeSetups.values
        where wait.account == account && wait.signedInMachine == nil
            && (wait.machine == nil || wait.machine == machine)
            && (wait.environment == nil || wait.environment == environment) {
            wait.signedInMachine = machine
        }
        connectionsChanged()
    }

    /// Waits until a connection serves `family`, checking at each ``connectionsChanged()``; false
    /// when the waiting task is cancelled (the page withdrew, the pane closed).
    public func waitUntilServed(family: String) async -> Bool {
        await waitUntilServed(family: family, claude: nil)
    }

    private func waitUntilServed(family: String, claude: ClaudeSetupWait?) async -> Bool {
        guard let read, !Task.isCancelled, claude == nil || claude?.account == accountScope?() else { return false }
        if claude?.signedInMachine != nil { return true }
        let seen = changes
        if await routed(read()).serves(family) == true { return true }
        if await gatewayServes(family) { return true }
        if changes == seen { await nextChange() }
        return await waitUntilServed(family: family, claude: claude)
    }

    /// Parks until the next ``connectionsChanged()`` or the waiting task's cancel.
    private func nextChange() async {
        let id = UUID(), wake = Wake()
        waiters[id] = wake
        await withTaskCancellationHandler {
            await withCheckedContinuation { wake.hold($0) }
        } onCancel: {
            wake.fire()
        }
        waiters[id] = nil
    }

    /// Runs the card's `action`, then waits for a connection serving `family` (``waitUntilServed(family:)``).
    public func setUp(_ action: Action, family: String, machine: String? = nil, environment: String? = nil) async -> SetupCompletion? {
        let id = UUID()
        let account = accountScope?()
        if family == "claude", let ready = await readyClaudeMachines(machine: machine, environment: environment).first {
            return SetupCompletion(machine: ready, usesMachineLogin: true, environment: environment, bindsEnvironment: true)
        }
        guard !Task.isCancelled, account == accountScope?() else { return nil }
        let claude = family == "claude" ? ClaudeSetupWait(machine: machine, account: account, environment: environment) : nil
        claudeSetups[id] = claude
        defer { claudeSetups[id] = nil }
        if let run {
            await run(action, family, machine)
        } else {
            let unscoped = machine == nil && environment == nil
            let oneClick = (action == .setUpClaude && family == "claude") || (action == .connectChatGPT && family == "codex")
            let started = unscoped && oneClick ? await connectInPlace?(action) == true : false
            guard !Task.isCancelled, account == accountScope?() else { return nil }
            if !started { openConnectionSettings?(family, machine, true, environment, nil) }
        }
        connectionsChanged()
        guard await waitUntilServed(family: family, claude: claude), !Task.isCancelled, account == accountScope?() else { return nil }
        let signedIn = claude?.signedInMachine
        return SetupCompletion(machine: signedIn ?? machine, usesMachineLogin: signedIn != nil, environment: environment, bindsEnvironment: true)
    }
}
