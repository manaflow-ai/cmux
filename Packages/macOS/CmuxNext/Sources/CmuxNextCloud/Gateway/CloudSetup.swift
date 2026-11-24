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

        public init(id: String, families: [String], signedIn: Bool = true, enabled: Bool = true, servesCloud: Bool = true, canServeCloud: Bool? = nil,
                    endpointProfile: Bool = false, endpointCredentials: Bool = false, launchHarness: String? = nil, subscriptionCredentials: Bool = false, kind: String? = nil) {
            (self.id, self.families, self.signedIn, self.enabled, self.servesCloud) = (id, families, signedIn, enabled, servesCloud)
            self.canServeCloud = canServeCloud ?? servesCloud
            (self.endpointProfile, self.endpointCredentials) = (endpointProfile, endpointCredentials)
            self.launchHarness = launchHarness
            self.subscriptionCredentials = subscriptionCredentials
            self.kind = kind
        }

        /// A `Connection` object of `_acpmux/connections`; nil for anything without an id.
        public init?(json: [String: Any]) {
            guard let id = json["id"] as? String, !id.isEmpty, json["kind"] as? String != "claude-token" else { return nil }
            self.init(id: id, families: json["cloud_families"] as? [String] ?? json["families"] as? [String] ?? [],
                      signedIn: json["signed_in"] as? Bool ?? true, enabled: json["enabled"] as? Bool ?? true,
                      servesCloud: json["serves_cloud"] as? Bool ?? true,
                      canServeCloud: json["can_serve_cloud"] as? Bool,
                      endpointProfile: json["kind"] as? String == "endpoint",
                      endpointCredentials: json["endpoint_credentials"] as? Bool == true, launchHarness: json["launch_harness"] as? String,
                      subscriptionCredentials: ["grok-plan", "copilot-plan"].contains(json["kind"] as? String ?? ""),
                      kind: json["kind"] as? String)
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
        /// serves Cloud for that family, else the first enabled Cloud-serving one of that family in
        /// the daemon's order, else the organization's shared key. When this Mac's connections
        /// are unread and there is no shared key, ``Choice/fallback`` represents unknown readiness.
        public func choice(family: String, model: String?, account: String?) -> Choice {
            if let personal {
                let serving = personal.filter { $0.enabled && $0.signedIn && $0.servesCloud && $0.families.contains(family) }
                if let pick = serving.first(where: { $0.id == account }) ?? serving.first { return .connection(id: pick.id, family: family) }
            }
            if organization?.contains(family) == true { return .organization(family: family) }
            return personal == nil ? .fallback : .setup(family: family, model: model)
        }

        /// Whether a connection serves `family`; nil when this Mac's connections were not read.
        public func serves(_ family: String) -> Bool? {
            switch choice(family: family, model: nil, account: nil) {
            case .connection, .organization, .gateway: true
            case .setup: false
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
        /// This Mac's connection `id` (an `_acpmux/connections` row): the start reads its credential
        /// (`_acpmux/connections/credential {id}`) and sends it with the agent launch to the machine.
        case connection(id: String, family: String)
        /// The organization's shared key for `family`, which the platform edge serves; nothing to send.
        case organization(family: String)
        /// The inference gateway of the team the machine is made in, in gateway mode and online, serves `family` (``gateway``): the machine's
        /// agent reaches it through the edge, so nothing is sent (hq#15762).
        case gateway(family: String)
        /// Nothing serves `family`: the chat shows Set up Cloud naming `model`, and nothing starts.
        case setup(family: String, model: String?)
        /// The snapshot has unknown readiness.
        case fallback

        /// This Mac's connection whose credential the chat's agent launch carries; nil for every other choice.
        public var connectionID: String? {
            if case .connection(let id, _) = self { return id }
            return nil
        }
    }

    /// The families a Cloud chat runs (the picker's agent, as the gateway names them).
    public nonisolated static let families = ["claude", "codex"]

    public nonisolated static let setupFamilies = families + nativeHarnesses.keys.sorted()

    private nonisolated static let nativeHarnesses = ["gemini": "gemini", "grok": "grok", "github-copilot": "opencode", "openrouter": "opencode"]

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
    /// Opens Settings > Cloud > Cloud models for the card's action and family while the send waits.
    public var run: (@MainActor (Action, String) async -> Void)?
    /// Reads confirmed endpoint harnesses on a machine named by the picker.
    public var machineHarnesses: (@MainActor (String) -> Set<String>?)?
    /// Reads confirmed runners that accept subscription credentials.
    public var machineSubscriptionHarnesses: (@MainActor (String) -> Set<String>?)?
    /// The owner's Claude chat can start before Claude Code has a login on its machine.
    public var canSignInToClaudeOnMachine: (@MainActor (String?) async -> Bool)?
    /// Opens Settings > Cloud > Cloud models for the family selected in the picker.
    public var openConnectionSettings: (@MainActor (String) -> Void)?

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

    private var waiters: [UUID: Wake] = [:]
    /// Bumped by every ``connectionsChanged()``: a wait whose read began before one reads again.
    private var changes = 0

    public init(read: (@MainActor () async -> Snapshot)? = nil, run: (@MainActor (Action, String) async -> Void)? = nil) {
        (self.read, self.run) = (read, run)
    }

    /// The connection a Cloud start on the picker's `harness`, `model` and `account` runs on. Lane F
    /// (app-to-machine credential delivery) reads ``Choice/connection(id:family:)``'s credential and
    /// sends it with the agent launch; ``Choice/setup(family:model:)`` shows the card instead.
    public func choose(harness: String?, model: String?, account: String?) async -> Choice {
        let snapshot = routed(await read?() ?? .init(personal: nil, organization: nil))
        if let profile = snapshot.personal?.first(where: { $0.endpointProfile && $0.id == harness }) {
            guard snapshot.serves(profile.id) == true else { return .setup(family: profile.id, model: model) }
            return snapshot.choice(family: profile.id, model: model, account: profile.id)
        }
        let name = harness ?? "claude"
        let normalized = name.lowercased()
        guard let family = Self.family(of: harness) ?? (Self.nativeHarnesses[normalized] == nil ? nil : normalized)
        else { return .fallback }
        let choice = snapshot.choice(family: family, model: model, account: account)
        guard case .setup = choice, await gatewayServes(family) else { return choice }
        return .gateway(family: family)
    }

    /// Whether the chosen connection needs the endpoint credential capability.
    public func launchConnection(_ connection: String?) async -> Connection? {
        guard let connection, let read else { return nil }
        let snapshot = await read()
        return snapshot.personal?.first(where: { $0.id == connection })
    }

    /// Whether the gateway of the team the machine is made in serves `family` now (``gateway``); false when it is unread, or when a start on it
    /// this run found no model route (``unrouted(harness:model:account:)``).
    private func gatewayServes(_ family: String) async -> Bool {
        guard !unroutedGateway.contains(family) else { return false }
        return await gateway?()?.contains(family) == true
    }

    /// The families whose team gateway a start found unrouted: for the rest of this run Set up Cloud waits for a
    /// connection of the person's own instead of starting again on the same gateway, as ``unroutedOrganization`` does.
    public private(set) var unroutedGateway: Set<String> = []

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
        case .gateway(let chosen): family = chosen; unroutedGateway.insert(chosen); connectionsChanged()
        default: return nil
        }
        guard case .setup(_, let model) = await choose(harness: harness, model: model, account: account) else { return nil }
        return (family, model)
    }

    /// `snapshot` without the organization families a start found unrouted.
    private func routed(_ snapshot: Snapshot) -> Snapshot {
        var snapshot = snapshot
        snapshot.organization?.subtract(unroutedOrganization)
        return snapshot
    }

    /// Per family a Cloud chat runs (``families``), whether a connection serves it now, from the same read a start
    /// makes (``Snapshot/serves(_:)``, without unrouted organization keys). A family the read could not decide is
    /// left out: "not served" needs both this Mac's connections and the team's keys read (a team key read that was
    /// still loading must not show Connect for a family the team serves). With no reader the answer is empty, and
    /// the picker shows nothing (`cloud.setup.state`).
    public func served(machine: String? = nil) async -> Readiness {
        guard let read else { return .init() }
        let snapshot = routed(await read())
        let nativeClaude = if snapshot.serves("claude") == true { false }
            else { await canSignInToClaudeOnMachine?(machine) == true }
        let profiles = snapshot.personal?.filter(\.endpointProfile) ?? []
        let usable = profiles.filter { $0.enabled && $0.signedIn && $0.servesCloud }
        let endpointRunners = machine.flatMap { machineHarnesses?($0) }
        let subscriptionRunners = machine.flatMap { machineSubscriptionHarnesses?($0) }
        func runners(for connection: Connection?) -> Set<String>? {
            connection?.subscriptionCredentials == true ? subscriptionRunners : endpointRunners
        }
        func chosenConnection(_ family: String) -> Connection? {
            guard let id = snapshot.choice(family: family, model: nil, account: nil).connectionID else { return nil }
            return snapshot.personal?.first { $0.id == id }
        }
        let configured = usable.compactMap { row in row.launchHarness.map { (id: row.id, runner: $0, confirmed: runners(for: row)) } }
            + Self.nativeHarnesses.filter { snapshot.serves($0.key) == true }
                .map { (id: $0.key, runner: $0.value, confirmed: runners(for: chosenConnection($0.key))) }
        let served = Array(Set(configured.filter { $0.confirmed?.contains($0.runner) == true }.map(\.id))).sorted()
        let pending = Array(Set(configured.filter { $0.confirmed == nil }.map(\.id))).sorted()
        let unavailable = (profiles.map(\.id) + configured.map(\.id)).filter { !served.contains($0) && !pending.contains($0) }
        let gatewayCandidates = Self.families.filter { snapshot.serves($0) == false && !unroutedGateway.contains($0) }
        let gatewayFamilies = gatewayCandidates.isEmpty ? nil : await gateway?()
        return (Self.families + Self.nativeHarnesses.keys.sorted()).reduce(into: Readiness(servedHarnesses: served, pendingHarnesses: pending, unavailableEndpointHarnesses: Array(Set(unavailable)).sorted())) { state, family in
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
            guard let serves = snapshot.serves(family), serves || snapshot.organization != nil else { return }
            if family == "claude", !serves, nativeClaude { return }
            state.families[family] = serves
            if !serves { state.reasons[family] = snapshot.connectionReason(for: family) }
        }
    }

    /// The picker's Connect shows the family's Settings destination.
    public func connect(family: String) {
        openConnectionSettings?(family)
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
        /// The Settings > Cloud row that sets `family` up (``Action/settingsRow``).
        public var settingsRow: String { (family == "codex" ? Action.connectChatGPT : Action.setUpClaude).settingsRow ?? "" }
    }

    /// ``decide(harness:model:)``'s setup answer, from the same one read; nil when the start goes on (something serves it,
    /// or nothing could be read).
    public func refusal(harness: String?, model: String?) async -> Refusal? {
        guard let family = Self.family(of: harness), let read else { return nil }
        let snapshot = routed(await read())
        guard case .setup(_, let model) = snapshot.choice(family: family, model: model, account: nil), !(await gatewayServes(family)) else { return nil }
        let local = snapshot.personal?.contains { $0.enabled && $0.signedIn && !$0.servesCloud && $0.families.contains(family) } == true
        return Refusal(family: family, model: model, localLogin: local)
    }

    /// The connections changed: every wait checks again.
    public func connectionsChanged() {
        changes += 1
        let woken = waiters
        waiters = [:]
        for wake in woken.values { wake.fire() }
    }

    /// Waits until a connection serves `family`, checking at each ``connectionsChanged()``; false
    /// when the waiting task is cancelled (the page withdrew, the pane closed).
    public func waitUntilServed(family: String) async -> Bool {
        guard let read else { return false }
        guard !Task.isCancelled else { return false }
        let seen = changes
        if await routed(read()).serves(family) != false { return true }
        if await gatewayServes(family) { return true }
        if changes == seen { await nextChange() } // else it changed while it read: read again now
        return await waitUntilServed(family: family)
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
    public func setUp(_ action: Action, family: String) async -> Bool {
        await run?(action, family)
        connectionsChanged()
        return await waitUntilServed(family: family)
    }
}
