public import Foundation
import os

/// Cloud first use (cmux-tui/docs/model-connections.md, "Cloud first use" and Revision 2): before a
/// Cloud chat starts, which connection serves the model the picker chose (``choose(harness:model:account:)``).
/// A personal one (`_acpmux/connections` on this Mac, served straight to the machine) or the
/// organization's shared key serving the picker's family starts the chat with no prompt; none shows
/// the chat's Set up Cloud card, which starts the chat by itself once one appears (``waitUntilServed(family:)``).
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
        /// The connection's kind (`chatgpt-plan`, `api-key`, `codex-login`, ...); nil when the row names none.
        public var kind: String?

        public init(id: String, families: [String], signedIn: Bool = true, enabled: Bool = true, servesCloud: Bool = true, kind: String? = nil) {
            (self.id, self.families, self.signedIn, self.enabled, self.servesCloud, self.kind) = (id, families, signedIn, enabled, servesCloud, kind)
        }

        /// A `Connection` object of `_acpmux/connections`; nil for anything without an id.
        public init?(json: [String: Any]) {
            guard let id = json["id"] as? String, !id.isEmpty else { return nil }
            self.init(id: id, families: (json["families"] as? [Any])?.compactMap { $0 as? String } ?? [],
                      signedIn: json["signed_in"] as? Bool ?? true, enabled: json["enabled"] as? Bool ?? true,
                      servesCloud: json["serves_cloud"] as? Bool ?? true, kind: json["kind"] as? String)
        }

        /// The Mac's Codex CLI ChatGPT login, the base one or an added account (`codex-login`, `subscription`; acpmux
        /// `connections.rs` `codex_login_serves_cloud`): its credential is `CMUX_CODEX_ACCESS_TOKEN`, which only a
        /// machine daemon with `agent-session-start-codex-login-credential-v1` takes (cmux#45774).
        public var isCodexLogin: Bool {
            families.contains("codex") && (kind == "codex-login" || kind == "subscription")
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
        ///
        /// `codexLogin` false: the machine's daemon takes no Codex CLI login (``Connection/isCodexLogin``), so none is chosen.
        public func choice(family: String, model: String?, account: String?, codexLogin: Bool = true) -> Choice {
            if let personal {
                let serving = personal.filter { $0.enabled && $0.signedIn && $0.servesCloud && $0.families.contains(family) && (codexLogin || !$0.isCodexLogin) }
                if let pick = serving.first(where: { $0.id == account }) ?? serving.first { return .connection(id: pick.id, family: family) }
            }
            if organization?.contains(family) == true { return .organization(family: family) }
            return personal == nil ? .fallback : .setup(family: family, model: model)
        }

        /// Whether a connection serves `family`; nil when this Mac's connections were not read.
        public func serves(_ family: String) -> Bool? {
            switch choice(family: family, model: nil, account: nil) {
            case .connection, .organization: true
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
    /// `codexLogin` false: for a machine whose daemon takes no Codex CLI login (``Snapshot/choice(family:model:account:codexLogin:)``).
    public func choose(harness: String?, model: String?, account: String?, codexLogin: Bool = true) async -> Choice {
        guard let family = Self.family(of: harness), let read else { return .fallback }
        return await routed(read()).choice(family: family, model: model, account: account, codexLogin: codexLogin)
    }

    /// Whether this Mac's connection `id` is its Codex CLI login (``Connection/isCodexLogin``); false for nil or a
    /// connection the read does not list.
    public func isCodexLogin(_ id: String?) async -> Bool {
        guard let id, let read else { return false }
        return await read().personal?.first { $0.id == id }?.isCodexLogin ?? false
    }

    /// Another of this Mac's connections for a start on `harness`, `model` and `account` whose chosen connection is the
    /// Codex CLI login and whose machine's daemon does not take it: the next one serving the family on Cloud that is not a
    /// Codex CLI login (a ChatGPT plan sign-in, an OpenAI key). Nil when none does: the organization's shared key is not
    /// one, as the machines get no model route from it now (``organizationUnrouted(_:)``).
    public func otherThanCodexLogin(harness: String?, model: String?, account: String?) async -> String? {
        await choose(harness: harness, model: model, account: account, codexLogin: false).connectionID
    }

    /// A start's chosen connection `id` for a machine whose daemon takes the Mac's Codex CLI login or not
    /// (`takesCodexLogin`, `agent-session-start-codex-login-credential-v1`): `id` itself, unless it is that login and the
    /// daemon does not take it; then the next connection serving the agent on Cloud (``otherThanCodexLogin(harness:model:account:)``).
    /// With none this throws ``CodexLoginUnsupported``: a start sent with it would be refused whole (cmux#45774).
    public func connection(_ id: String?, harness: String?, model: String?, account: String?, takesCodexLogin: Bool) async throws -> String? {
        guard !takesCodexLogin, await isCodexLogin(id) else { return id }
        guard let other = await otherThanCodexLogin(harness: harness, model: model, account: account) else { throw CodexLoginUnsupported() }
        return other
    }

    /// The machine's daemon does not take the start's Codex CLI login, and no other connection serves its agent on Cloud.
    public struct CodexLoginUnsupported: Error, Equatable, Sendable {
        public init() {}
    }

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
    /// (`CloudMachineRoute.NeedsConnection`): when it ran on the organization's shared key, that key is unrouted
    /// (``organizationUnrouted(_:)``), and the answer is the Set up Cloud card's family and model where the next choice
    /// is that card. Nil for anything else (connections unread, an agent Cloud does not serve): the card could never pass.
    public func unrouted(harness: String?, model: String?, account: String?) async -> (family: String, model: String?)? {
        guard case .organization(let family) = await choose(harness: harness, model: model, account: account) else { return nil }
        organizationUnrouted(family)
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
        if case .setup(let family, let model) = await choose(harness: harness, model: model, account: nil) { return .setup(family: family, model: model) }
        return .start
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
