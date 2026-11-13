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
    /// an acpmux before `_acpmux/connections`); `organization` nil: the team's keys could not be read
    /// (signed out, a failed read). Either unread never shows Set up Cloud.
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
        /// the daemon's order, else the organization's shared key. Set up Cloud only when both were read
        /// and neither serves: with this Mac's connections or the team's keys unread (no daemon, an
        /// acpmux before `_acpmux/connections`, a team key read that failed) the answer is
        /// ``Choice/fallback`` and the chat starts as before.
        public func choice(family: String, model: String?, account: String?) -> Choice {
            if let personal {
                let serving = personal.filter { $0.enabled && $0.signedIn && $0.servesCloud && $0.families.contains(family) }
                if let pick = serving.first(where: { $0.id == account }) ?? serving.first { return .connection(id: pick.id, family: family) }
            }
            if organization?.contains(family) == true { return .organization(family: family) }
            return personal == nil || organization == nil ? .fallback : .setup(family: family, model: model)
        }

        /// Whether a connection serves `family`; nil when this Mac's connections or the team's keys were not read.
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
    /// Told true when a wait begins and false when the last one ends: the reader watches the
    /// connections (acpmux's `_acpmux/connections.changed`) only while someone waits.
    public var watching: (@MainActor (Bool) -> Void)?

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
    /// The waits in progress (``watching``).
    private var waits = 0

    public init(read: (@MainActor () async -> Snapshot)? = nil, run: (@MainActor (Action) async -> Void)? = nil) {
        (self.read, self.run) = (read, run)
    }

    /// The connection a Cloud start on the picker's `harness`, `model` and `account` runs on. Lane F
    /// (app-to-machine credential delivery) reads ``Choice/connection(id:family:)``'s credential and
    /// sends it with the agent launch; ``Choice/setup(family:model:)`` shows the card instead.
    public func choose(harness: String?, model: String?, account: String?) async -> Choice {
        guard let family = Self.family(of: harness), let read else { return .fallback }
        return await read().choice(family: family, model: model, account: account)
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
        guard read != nil else { return true } // nothing to read: every start goes as before
        waits += 1
        if waits == 1 { watching?(true) }
        defer {
            waits -= 1
            if waits == 0 { watching?(false) }
        }
        return await served(family)
    }

    /// One read, then (nothing serving yet) the next change and another read.
    private func served(_ family: String) async -> Bool {
        guard let read else { return true }
        guard !Task.isCancelled else { return false }
        let seen = changes
        if await read().serves(family) != false { return true }
        if changes == seen { await nextChange() } // else it changed while it read: read again now
        return await served(family)
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
