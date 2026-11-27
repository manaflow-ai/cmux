public import Foundation
import os

/// Cloud first use (cmux-tui/docs/model-connections.md, "Cloud first use" and Revision 2): before a
/// Cloud chat starts, which connection serves the model the picker chose (``choose(harness:model:account:)``).
/// A personal one (`_acpmux/connections` on this Mac, served straight to the machine) or the
/// organization's shared key serving the picker's family starts the chat with no prompt; none shows
/// the chat's Set up Cloud card, which starts the chat by itself once one appears (``waitUntilServed(family:)``).
/// With none of those, a team in inference gateway mode whose gateway is online (``gateway``) serves the chat too.
///
/// What it reads and how it connects are seams the App fills (``read``, ``run``): the Settings >
/// Models ops own the connections; this holds only the rule and the wait. Every change to the
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

        public init(id: String, families: [String], signedIn: Bool = true, enabled: Bool = true, servesCloud: Bool = true) {
            (self.id, self.families, self.signedIn, self.enabled, self.servesCloud) = (id, families, signedIn, enabled, servesCloud)
        }

        /// A `Connection` object of `_acpmux/connections`; nil for anything without an id.
        public init?(json: [String: Any]) {
            guard let id = json["id"] as? String, !id.isEmpty else { return nil }
            self.init(id: id, families: (json["families"] as? [Any])?.compactMap { $0 as? String } ?? [],
                      signedIn: json["signed_in"] as? Bool ?? true, enabled: json["enabled"] as? Bool ?? true,
                      servesCloud: json["serves_cloud"] as? Bool ?? true)
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
        /// the daemon's order, else the organization's shared key. With this Mac's connections unread
        /// (no daemon, an acpmux before `_acpmux/connections`) and no shared key the answer is
        /// ``Choice/fallback``: the chat starts as before.
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
        /// Nothing to choose (an agent Cloud does not serve, or connections that could not be read):
        /// the chat starts as before, on the machine's own path.
        case fallback

        /// This Mac's connection whose credential the chat's agent launch carries; nil for every other choice.
        public var connectionID: String? {
            if case .connection(let id, _) = self { return id }
            return nil
        }

        /// Whether the chat's model calls go somewhere other than this Mac's own gateway (``PersonalGateway``): the
        /// agent launch carries this Mac's connection credential, or the platform edge serves the organization's key.
        /// A start then has no gateway to wait for before its first turn. The production probe's starts on such a
        /// route waited out the gateway's whole 10 s deadline in about one in five runs (2026-11-21).
        public var servedWithoutMacGateway: Bool {
            switch self {
            case .connection, .organization: true
            case .gateway, .setup, .fallback: false
            }
        }
    }

    /// The families a Cloud chat runs (the picker's agent, as the gateway names them).
    public nonisolated static let families = ["claude", "codex"]

    /// The family of the picker's agent (`claude`, `codex`, or a harness profile named after one);
    /// nil for an agent Cloud's gateway does not serve, which the rule never holds back.
    public nonisolated static func family(of harness: String?) -> String? {
        let name = (harness ?? "claude").lowercased()
        return families.first { name == $0 || name.hasPrefix($0 + "-") || name.hasPrefix($0 + ":") }
    }

    /// The decision for one start.
    public enum Decision: Equatable, Sendable {
        /// A connection serves the picker's model (or nothing could be read): start with no prompt.
        case start
        /// Nothing serves `family`: the chat shows Set up Cloud naming `model`.
        case setup(family: String, model: String?)
    }

    /// The card's ways in (`cloud.setUp {action}`), the Settings > Models ops they run.
    public enum Action: String, Sendable, CaseIterable {
        case connectChatGPT, setUpClaude, addKey, openSettings

        /// The Settings > Cloud row this action opens on (Models for Cloud); nil opens the page.
        public var settingsRow: String? {
            switch self {
            case .setUpClaude: "claude"
            case .connectChatGPT: "chatgpt"
            case .addKey: "apiKey"
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

    /// Reads what serves Cloud now; nil leaves every start as it was.
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
    /// Runs one of the card's ways in (Settings > Models' `cmux.settings.models.run` actions
    /// `connectChatGPT`, `claudeSetupToken`; `addKey` and `openSettings` open Settings > Models).
    public var run: (@MainActor (Action) async -> Void)?

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

    public init(read: (@MainActor () async -> Snapshot)? = nil, run: (@MainActor (Action) async -> Void)? = nil) {
        (self.read, self.run) = (read, run)
    }

    /// The connection a Cloud start on the picker's `harness`, `model` and `account` runs on. Lane F
    /// (app-to-machine credential delivery) reads ``Choice/connection(id:family:)``'s credential and
    /// sends it with the agent launch; ``Choice/setup(family:model:)`` shows the card instead.
    public func choose(harness: String?, model: String?, account: String?) async -> Choice {
        guard let family = Self.family(of: harness), let read else { return .fallback }
        let choice = await routed(read()).choice(family: family, model: model, account: account)
        guard case .setup = choice, await gatewayServes(family) else { return choice }
        return .gateway(family: family)
    }

    /// Whether the gateway of the team the machine is made in serves `family` now (``gateway``); false when it is unread, or when a start on it
    /// found no model route within ``gatewayUnroutedHold`` (``unrouted(harness:model:account:)``).
    private func gatewayServes(_ family: String) async -> Bool {
        guard !unroutedGateway.contains(family) else { return false }
        gatewayRead = nil // this read's own, never an earlier one's
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
        snapshot.organization?.subtract(unroutedOrganization)
        return snapshot
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
    public func refusal(harness: String?, model: String?) async -> Refusal? {
        guard let family = Self.family(of: harness), let read else { return nil }
        let snapshot = routed(await read())
        guard case .setup(_, let model) = snapshot.choice(family: family, model: model, account: nil), !(await gatewayServes(family)) else { return nil }
        let local = snapshot.personal?.contains { $0.enabled && $0.signedIn && !$0.servesCloud && $0.families.contains(family) } == true
        return Refusal(family: family, model: model, localLogin: local, gateway: gatewayRead)
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

    /// Waits until a connection serves `family`, checking at each ``connectionsChanged()``; false
    /// when the waiting task is cancelled (the page withdrew, the pane closed).
    public func waitUntilServed(family: String) async -> Bool {
        guard let read else { return true } // nothing to read: every start goes as before
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
        await run?(action)
        connectionsChanged()
        return await waitUntilServed(family: family)
    }
}
