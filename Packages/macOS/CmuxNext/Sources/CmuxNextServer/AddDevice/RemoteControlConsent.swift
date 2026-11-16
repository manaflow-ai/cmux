public import CmuxNextSettings
public import Foundation
public import Observation

/// What one owned machine's consent service answered (`_acpmux/consent_remote_status`, and the `ok`
/// answer of `_acpmux/consent_remote_set`): who it is, what it allows, whether it trusts this Mac's key,
/// and its last log lines. `self` (this Mac's own account, key id and words) comes with a status read only.
public nonisolated struct RemoteControlStatus: Equatable, Sendable {
    /// One line of the target's grant log (`grants.jsonl`).
    public struct LogLine: Equatable, Sendable {
        public var at: Double
        /// `grant`, `revoke`, `refused`, `pinned`, `unpinned` or `ask`.
        public var event: String
        /// `local`, or a grantor id.
        public var by: String
        public var name: String?
        public var surface: String?
        public var reason: String?

        public init(at: Double, event: String, by: String, name: String? = nil, surface: String? = nil, reason: String? = nil) {
            self.at = at
            self.event = event
            self.by = by
            self.name = name
            self.surface = surface
            self.reason = reason
        }
    }

    public var machineId: String?
    public var nodeKey: String?
    /// The account the target is enrolled under.
    public var account: String?
    public var control: Bool
    public var screen: Bool
    /// Whether the target trusts this Mac's key; nil when it did not say (this Mac has no key).
    public var pinned: Bool?
    public var log: [LogLine]
    /// This Mac's own account (`self.account`), the one a grant is signed for.
    public var selfAccount: String?
    public var selfGrantor: String?
    /// This Mac's key's four words, which the target's ask shows.
    public var selfWords: [String]?
    /// Where the target's Control comes from (`effective.control.source`): `local`, `machine`, `account` or `none`.
    public var controlSource: String?

    public init(machineId: String? = nil, nodeKey: String? = nil, account: String? = nil, control: Bool = false, screen: Bool = false,
                pinned: Bool? = nil, log: [LogLine] = [], selfAccount: String? = nil, selfGrantor: String? = nil, selfWords: [String]? = nil,
                controlSource: String? = nil) {
        self.machineId = machineId
        self.nodeKey = nodeKey
        self.account = account
        self.control = control
        self.screen = screen
        self.pinned = pinned
        self.log = log
        self.selfAccount = selfAccount
        self.selfGrantor = selfGrantor
        self.selfWords = selfWords
        self.controlSource = controlSource
    }

    /// The status in an `ok: true` answer; nil for any other.
    public static func parse(_ answer: [String: Any]) -> RemoteControlStatus? {
        guard answer["ok"] as? Bool == true else { return nil }
        let text = { (key: String) -> String? in (answer[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let mine = answer["self"] as? [String: Any]
        let log = (answer["grantLog"] as? [[String: Any]] ?? []).suffix(20).compactMap { line -> LogLine? in
            guard let event = line["event"] as? String, let by = line["by"] as? String else { return nil }
            let at = (line["at"] as? NSNumber)?.doubleValue ?? 0
            return LogLine(at: at, event: event, by: by, name: line["name"] as? String, surface: line["surface"] as? String,
                           reason: line["reason"] as? String)
        }
        return RemoteControlStatus(
            machineId: text("machineId"), nodeKey: text("nodeKey"), account: text("account"),
            control: answer["control"] as? Bool == true, screen: answer["screen"] as? Bool == true,
            pinned: (answer["grantor"] as? [String: Any])?["pinned"] as? Bool, log: Array(log),
            selfAccount: (mine?["account"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            selfGrantor: (mine?["grantor"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            selfWords: (mine?["words"] as? [String]).map { Array($0.prefix(4)) },
            controlSource: ((answer["effective"] as? [String: Any])?["control"] as? [String: Any])?["source"] as? String)
    }

    /// The same status with `self` kept from `previous` (a set's answer carries none).
    func keepingSelf(of previous: RemoteControlStatus?) -> RemoteControlStatus {
        guard selfAccount == nil, selfGrantor == nil, selfWords == nil, let previous else { return self }
        var status = self
        status.selfAccount = previous.selfAccount
        status.selfGrantor = previous.selfGrantor
        status.selfWords = previous.selfWords
        return status
    }
}

/// What the owner side asks of the app, so tests run it with fakes. Every call runs on the main actor.
@MainActor public struct RemoteControlConsentServices {
    /// One request to this Mac's acpmux over a person-proof line: its `result`, or the error to show.
    public var call: @MainActor (_ method: String, _ params: [String: Any]) async -> Result<[String: Any], RemoteControlCallError>
    /// SECURITY: signs a grant with this Mac's key (``AcpmuxMacApprover/consentGrant``) for `account`,
    /// turning both surfaces `on`, off or back to the account's (nil) on the machine (`*`: every machine);
    /// nil when there is no key. An on reaches this only after the person's own HID gesture and Touch ID
    /// or the password, or from the person's own sign-in on this Mac (``RemoteControlConsent/signedIn()``).
    public var sign: @MainActor (_ account: String, _ machineId: String, _ nodeKey: String, _ on: Bool?, _ name: String) async -> [String: any Sendable]?
    /// This Mac's name, which the target's ask shows (not signed).
    public var thisMacName: @MainActor () -> String
    public var now: @MainActor () -> Date
    /// The block shows: this Mac is joined with labs.machineJoin on (``JoinConsentModel/shown``).
    public var shown: @MainActor () -> Bool = { false }
    /// This Mac's own machine id, which gets no row.
    public var thisMac: @MainActor () -> String? = { nil }
    /// The person's joined machines (``JoinedMachineStore/machines``), and a read of them.
    public var machines: @MainActor () -> [JoinedMachine] = { [] }
    public var refreshMachines: @MainActor () async -> Void = {}
    /// The Labs switch (`labs.machineJoin`), and this Mac's consent record (account, account-wide grant) and its read.
    public var enabled: @MainActor () -> Bool = { false }
    public var record: @MainActor () -> JoinConsentRecord? = { nil }
    public var refreshRecord: @MainActor () async -> Void = {}

    public init(call: @escaping @MainActor (String, [String: Any]) async -> Result<[String: Any], RemoteControlCallError>,
                sign: @escaping @MainActor (String, String, String, Bool?, String) async -> [String: any Sendable]?,
                thisMacName: @escaping @MainActor () -> String, now: (@MainActor () -> Date)? = nil) {
        self.call = call
        self.sign = sign
        self.thisMacName = thisMacName
        self.now = now ?? { Date() }
    }

    /// The app's: requests over the join model's person line, rows from the joined machines, and `signer`
    /// (this Mac's approver key, ``AcpmuxMacApprover/consentSigner``; nil: nothing is signed).
    public static func over(join: JoinConsentModel, machines: JoinedMachineStore,
                            signer: (@Sendable (String, String, String, Bool?, String) async -> [String: any Sendable]?)?) -> Self {
        var services = Self(call: { [weak join] method, params in
            await join?.personCall(method, params) ?? .failure(RemoteControlCallError(nil))
        }, sign: { await signer?($0, $1, $2, $3, $4) }, thisMacName: { [weak join] in join?.status?.name ?? join?.status?.machineId ?? "Mac" })
        services.shown = { [weak join] in join?.shown == true }
        services.thisMac = { [weak join] in join?.status?.machineId }
        services.machines = { [weak machines] in machines?.machines ?? [] }
        services.refreshMachines = { [weak machines] in await machines?.refresh() }
        services.enabled = { [weak join] in join?.enabled == true }
        services.record = { [weak join] in join?.consent }
        services.refreshRecord = { [weak join] in await join?.refresh() }
        return services
    }
}

/// A request acpmux did not answer with a result: its own words, or none.
public nonisolated struct RemoteControlCallError: Error, Equatable, Sendable {
    public var message: String?
    public init(_ message: String?) { self.message = message }
}

/// Control and Screen sharing between the person's own devices, from this Mac: the one entry point
/// Settings > Devices ("Control between my devices", `devices_control` in the host lists) and the Screen
/// Sharing rows use. A switch for all of them (an account-wide grant, ``setAccount(on:)``) and one per
/// machine the person owns (``JoinedMachine``, not revoked, with a mesh id) that narrows it there
/// (``set(machineID:on:)``), each a grant this Mac's key signs. Each machine's status is read when its row
/// or ``state(for:)`` first asks, again each time Settings > Devices shows (``pageShown()``), a failed one
/// again when it is a minute old and asked, and after each set. No timer: nothing reads unasked. A machine
/// that leaves the list is forgotten with any read still under way for it.
///
/// SECURITY: this signs what it is asked to. A caller turning anything on (one machine, all of them) first
/// takes the person's own HID gesture and then Touch ID or the password, and ``refreshTrust()`` takes the
/// gesture (Settings > Devices' ops, ``RemoteControlConsentPage``); off and back-to-default only narrow and
/// need neither. The one on with no gesture is ``signedIn()``, which rides on the person signing in here.
/// Trust residual (contract v2 B): a machine pins this Mac's key with no prompt only during its own
/// enrollment step; a Mac that signs in later is pinned on that machine's next enrollment step or
/// "Refresh trusted Macs" there, else through the four-word ask its first grant leaves.
@MainActor @Observable
public final class RemoteControlConsent {
    /// One machine's switch as the Screen Sharing rows show it.
    public struct State: Equatable, Sendable {
        /// Where `on` comes from: a setting on that machine, its own grant from a Mac, the account's, or nothing.
        public enum Source: String, Sendable { case local, machine, account, none }
        public var on: Bool
        public var source: Source
        public var busy: Bool
        public var error: String?
    }

    public enum Entry: Equatable {
        case known(RemoteControlStatus)
        /// acpmux could not reach it (`machine.unreachable`).
        case unreachable(last: RemoteControlStatus?)
        case failed(String, last: RemoteControlStatus?)
    }

    public private(set) var entries: [String: Entry] = [:]
    /// The machines a set is running on (the switch is disabled meanwhile).
    public private(set) var setting: Set<String> = []
    /// The last set's error, by machine, until the next set.
    public private(set) var errors: [String: String] = [:]
    /// The words a machine's refusal (`grant.unpinned`) showed: it holds this Mac's ask until its person allows it.
    public private(set) var asks: [String: [String]] = [:]
    /// Bumped by ``pageShown()``: every entry read before it is read again when drawn.
    public private(set) var shownEpoch = 0
    @ObservationIgnored private var readEpoch: [String: Int] = [:]
    @ObservationIgnored private var readAt: [String: Date] = [:]
    @ObservationIgnored private var reading: [String: (generation: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var generation: [String: Int] = [:]
    @ObservationIgnored private let services: RemoteControlConsentServices
    /// The switch for all the person's devices is being set, and why its last set failed.
    public private(set) var settingAccount = false
    public private(set) var accountError: String?
    public static let retryAfter: TimeInterval = 60

    public init(services: RemoteControlConsentServices) {
        self.services = services
    }

    /// The machines that get a row: not revoked, with a mesh id (the node key a grant names).
    public static func eligible(_ machines: [JoinedMachine]) -> [JoinedMachine] {
        machines.filter { $0.state != .revoked && $0.meshPeerId?.isEmpty == false }
    }

    /// Settings > Devices showed: each row is read again when next drawn.
    public func pageShown() {
        guard services.shown() else { return }
        shownEpoch += 1
        let refresh = services.refreshMachines
        // main-hop-allow: one joined-machine list read per Devices card mount (a person's page op); it awaits
        // the CLI off the main actor and applies one array, then ends.
        // task-owner: ends with the read.
        Task { @MainActor in await refresh() }
    }

    /// The host lists' `devices_control`: null unless the block shows (this Mac joined, labs.machineJoin on).
    public var hostJSON: JSONValue {
        guard services.shown() else { return .null }
        return pageData(machines: services.machines(), thisMac: services.thisMac()).flatMap { try? JSONValue.parse($0) } ?? .null
    }

    /// The switch of the machine `machineID` names (only a row the block shows): on, off, or nil, back to
    /// the switch for all devices. The error to show, or nil.
    public func set(machineID: String, on: Bool?) async -> String? {
        guard let machine = owned(machineID) else { return RemoteControlStrings.notOwned }
        return await set(machine, on: on)
    }

    /// The machine `machineID` names, when it gets a row: the block shows and it is not this Mac.
    private func owned(_ machineID: String) -> JoinedMachine? {
        guard services.shown(), machineID != services.thisMac() else { return nil }
        return Self.eligible(services.machines()).first(where: { $0.id == machineID })
    }

    /// The machine's switch, starting its read as a drawn row does; nil when it gets no row.
    public func state(for machineID: String) -> State? {
        guard let machine = owned(machineID) else { return nil }
        let entry = entry(machine)
        let status = Self.known(entry)
        var error = errors[machineID]
        if error == nil, case .failed(let why, _) = entry { error = why }
        if error == nil, case .unreachable = entry { error = RemoteControlStrings.offline }
        return State(on: status?.control == true, source: status?.controlSource.flatMap(State.Source.init(rawValue:)) ?? .none,
                     busy: setting.contains(machineID), error: error)
    }

    /// The switch for all the person's devices: one account-wide grant (machine id and node key `*`) this
    /// Mac signs for its account, which acpmux applies here and hands to every machine of the account
    /// (`_acpmux/consent_account_set`). The error to show, or nil.
    public func setAccount(on: Bool) async -> String? {
        guard services.shown() else { return RemoteControlStrings.notOwned }
        guard !settingAccount else { return RemoteControlStrings.busy }
        settingAccount = true
        defer { settingAccount = false }
        let account = services.record()?.account ?? entries.values.lazy.compactMap { Self.known($0)?.selfAccount }.first
        let error = await sendAccount(account, on: on)
        accountError = error
        await services.refreshRecord()
        shownEpoch += 1
        return error
    }

    /// The person signed in on this Mac (a person step, so no gesture): when acpmux has no account-wide grant
    /// yet (`accountPolicy` null), one turns Control and Screen sharing on for all their devices (contract
    /// v2 C). Nothing with the Labs switch off, a policy already there (on or off), or an acpmux that does
    /// not report one.
    public func signedIn() async {
        guard services.enabled(), case .success(let answer) = await services.call("_acpmux/machine_consent_get", [:]),
              let record = JoinConsentRecord.parse(answer), record.reportsAccountPolicy, record.accountPolicy == nil else { return }
        _ = await sendAccount(record.account, on: true)
        await services.refreshRecord()
    }

    private func sendAccount(_ account: String?, on: Bool) async -> String? {
        guard let account else { return RemoteControlStrings.signedOut }
        guard let grant = await services.sign(account, "*", "*", on, services.thisMacName()) else { return RemoteControlStrings.noKey }
        switch await services.call("_acpmux/consent_account_set", ["grant": grant]) {
        case .failure(let error): return error.message ?? RemoteControlStrings.setFailed
        case .success(let answer): return Self.refusal(answer)
        }
    }

    /// "Refresh trusted Macs": acpmux collects the keys of the account's Macs again now (`_acpmux/consent_trust_refresh`);
    /// the person's gesture asked it. Every row is read again after. The error to show, or nil.
    public func refreshTrust() async -> String? {
        let error: String?
        switch await services.call("_acpmux/consent_trust_refresh", [:]) {
        case .failure(let failure): error = failure.message ?? RemoteControlStrings.setFailed
        case .success(let answer): error = Self.refusal(answer)
        }
        shownEpoch += 1
        return error
    }

    /// nil for an `ok: true` answer, else its error or the plain failure.
    private static func refusal(_ answer: [String: Any]) -> String? {
        answer["ok"] as? Bool == true ? nil : (answer["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? RemoteControlStrings.setFailed
    }

    /// The entry for `machine`, starting its read when none is known, the page showed again since the
    /// last read, or the last failed a minute ago.
    public func entry(_ machine: JoinedMachine) -> Entry? {
        let entry = entries[machine.id]
        if stale(machine.id, entry), !setting.contains(machine.id), reading[machine.id] == nil, let peer = machine.meshPeerId {
            read(machine.id, peer: peer)
        }
        return entry
    }

    private func stale(_ id: String, _ entry: Entry?) -> Bool {
        guard let entry else { return true }
        if readEpoch[id, default: -1] != shownEpoch { return true }
        if case .known = entry { return false }
        return services.now().timeIntervalSince(readAt[id] ?? .distantPast) >= Self.retryAfter
    }

    private func read(_ id: String, peer: String) {
        let started = generation[id, default: 0]
        let epoch = shownEpoch
        // main-hop-allow: a status read awaits acpmux off the main actor, then writes one entry (the next host-list
        // draw takes it); bounded by one read per drawn row, and none while the page is hidden.
        // task-owner: one status read for one machine; `keep(only:)` cancels it, and a set overtakes it (generation).
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let entry = await status(id, peer: peer)
            if reading[id]?.generation == started { reading[id] = nil }
            guard generation[id, default: 0] == started else { return }
            apply(entry, to: id, epoch: epoch)
        }
        reading[id] = (started, task)
    }

    private func apply(_ entry: Entry, to id: String, epoch: Int) {
        if case .known(let status) = entry, status.pinned == true { asks[id] = nil }
        entries[id] = entry
        readEpoch[id] = epoch
        readAt[id] = services.now()
    }

    /// One `_acpmux/consent_remote_status` for the machine whose node key is `peer`.
    private func status(_ id: String, peer: String) async -> Entry {
        let last = Self.known(entries[id])
        switch await services.call("_acpmux/consent_remote_status", ["daemonId": peer]) {
        case .failure(let error):
            return .failed(error.message ?? RemoteControlStrings.readFailed, last: last)
        case .success(let answer):
            if let status = RemoteControlStatus.parse(answer) { return .known(status) }
            if answer["reason"] as? String == "machine.unreachable" { return .unreachable(last: last) }
            return .failed((answer["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? RemoteControlStrings.readFailed, last: last)
        }
    }

    /// Turns `machine`'s Control and Screen sharing both on, both off, or both back to the switch for all
    /// devices (nil) with a grant this Mac signs: the error to show, or nil. Reads the machine's status first and signs only for the machine the row
    /// names: its answer's machine id and node key must equal the row's id and mesh id, or nothing is signed.
    /// Reads again after, whichever way it went.
    public func set(_ machine: JoinedMachine, on: Bool?) async -> String? {
        let id = machine.id
        guard !setting.contains(id) else { return RemoteControlStrings.busy }
        guard machine.state != .revoked, let peer = machine.meshPeerId, !peer.isEmpty else { return RemoteControlStrings.notOwned }
        setting.insert(id)
        defer { setting.remove(id) }
        generation[id, default: 0] += 1
        let mine = generation[id, default: 0]
        reading.removeValue(forKey: id)?.task.cancel()
        let error = await write(machine, peer: peer, on: on)
        let fresh = await status(id, peer: peer)
        // Forgotten meanwhile (the machine left the list): nothing of it is kept.
        if generation[id, default: 0] == mine {
            errors[id] = error
            apply(fresh, to: id, epoch: shownEpoch)
        }
        return error
    }

    private func write(_ machine: JoinedMachine, peer: String, on: Bool?) async -> String? {
        let status: RemoteControlStatus
        switch await self.status(machine.id, peer: peer) {
        case .known(let known): status = known
        case .unreachable: return RemoteControlStrings.offline
        case .failed(let why, _): return why
        }
        // SECURITY: the machine list names the row (the platform supplies it); the target's own answer
        // must name the same machine and node key before this Mac signs anything for it.
        guard status.machineId == machine.id, status.nodeKey == peer else { return RemoteControlStrings.mismatch(machine.name) }
        guard let account = status.selfAccount else { return RemoteControlStrings.signedOut }
        guard status.account == account else { return RemoteControlStrings.otherAccount(machine.name) }
        guard let grant = await services.sign(account, machine.id, peer, on, services.thisMacName()) else { return RemoteControlStrings.noKey }
        switch await services.call("_acpmux/consent_remote_set", ["daemonId": peer, "grant": grant]) {
        case .failure(let error):
            return error.message ?? RemoteControlStrings.setFailed
        case .success(let answer):
            if answer["ok"] as? Bool == true {
                asks[machine.id] = nil
                return nil
            }
            let reason = answer["reason"] as? String
            if reason == "grant.unpinned" {
                // The target recorded this Mac's ask: its person allows it once, matching the words.
                asks[machine.id] = (answer["words"] as? [String]).map { Array($0.prefix(4)) } ?? status.selfWords ?? []
                return nil
            }
            if reason == "machine.unreachable" { return RemoteControlStrings.offline }
            return (answer["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? RemoteControlStrings.setFailed
        }
    }

    /// Forgets the machines not in `machines` (they left the list or were revoked), with any read under way.
    public func keep(only machines: [JoinedMachine]) {
        let ids = Set(machines.map(\.id))
        for id in Set(entries.keys).union(reading.keys).subtracting(ids) {
            generation[id, default: 0] += 1
            reading.removeValue(forKey: id)?.task.cancel()
            entries[id] = nil
            errors[id] = nil
            asks[id] = nil
            readAt[id] = nil
            readEpoch[id] = nil
        }
    }

    private static func known(_ entry: Entry?) -> RemoteControlStatus? {
        switch entry {
        case .known(let status): status
        case .unreachable(let last): last
        case .failed(_, let last): last
        case nil: nil
        }
    }

    // MARK: The page

    /// Settings > Devices' `devices_control` block for `machines` (the joined machines the person owns,
    /// but `thisMac`, this Mac's own machine id): the rows, this Mac's words, and reads started for rows
    /// that need one.
    public func pageData(machines: [JoinedMachine], thisMac: String? = nil) -> Data? {
        let rows = Self.eligible(machines).filter { $0.id != thisMac }
        keep(only: rows)
        let made = rows.map { row($0) }
        let words = entries.values.lazy.compactMap { Self.known($0)?.selfWords }.first
        let page: [String: Any] = [
            "title": RemoteControlStrings.title,
            "help": RemoteControlStrings.help,
            "account": [
                "title": RemoteControlStrings.accountTitle, "help": RemoteControlStrings.accountHelp,
                "on": services.record()?.accountPolicy?.control == true, "busy": settingAccount,
                "error": accountError.map { $0 as Any } ?? NSNull(),
            ] as [String: Any],
            "refresh": RemoteControlStrings.refresh,
            "this_mac_words": words.map { $0 as Any } ?? NSNull(),
            "error": NSNull(),
            "rows": made,
        ]
        return try? JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])
    }

    /// One row: its switch, its status word and its one localized line.
    func row(_ machine: JoinedMachine) -> [String: Any] {
        let entry = entry(machine)
        let status = Self.known(entry)
        let busy = setting.contains(machine.id)
        let ask = asks[machine.id] ?? Self.pendingAsk(status)
        let word: String, detail: String
        if let error = errors[machine.id] {
            (word, detail) = ("error", error)
        } else if case .failed(let why, _) = entry {
            (word, detail) = ("error", why)
        } else if case .unreachable = entry {
            (word, detail) = ("offline", RemoteControlStrings.offline)
        } else if let status, status.pinned != true, let ask {
            (word, detail) = ("ask_pending", RemoteControlStrings.askPending(machine.name, words: ask))
        } else if let status {
            word = status.control ? "on" : "off"
            detail = detailLine(status, machine: machine)
        } else if machine.state == .offline {
            (word, detail) = ("offline", RemoteControlStrings.offline)
        } else {
            (word, detail) = ("unknown", RemoteControlStrings.checking)
        }
        let showsWords = word == "ask_pending"
        var unreachable = false
        if case .unreachable = entry { unreachable = true }
        return [
            "id": machine.id, "name": machine.name, "platform": machine.platform ?? "",
            "online": machine.state == .online && !unreachable,
            "on": status?.control == true, "busy": busy, "status": word, "detail": detail,
            "source": status?.controlSource.map { $0 as Any } ?? NSNull(),
            "words": showsWords ? (ask ?? []) as Any : NSNull(),
            "log": (status?.log ?? []).reversed().map { line in
                ["time": Self.time(line.at), "what": what(line, machine: machine, status: status)]
            },
        ]
    }

    /// The target recorded this Mac's ask and nobody answered it since: the newest of its ask, pin and
    /// unpin lines for this Mac's key is the ask. Its words are this Mac's own.
    private static func pendingAsk(_ status: RemoteControlStatus?) -> [String]? {
        guard let status, status.pinned == false, let me = status.selfGrantor else { return nil }
        let last = status.log.last(where: { $0.by == me && ["ask", "pinned", "unpinned"].contains($0.event) })
        return last?.event == "ask" ? (status.selfWords ?? []) : nil
    }

    /// "Turned on from this Mac · 5 min ago", from the target's newest grant or revoke line.
    /// From the account's switch: "On for all your devices".
    private func detailLine(_ status: RemoteControlStatus, machine: JoinedMachine) -> String {
        if status.controlSource == "account" { return status.control ? RemoteControlStrings.accountOn : RemoteControlStrings.accountOff }
        let change = status.log.last(where: { ($0.event == "grant" || $0.event == "revoke") && ($0.surface == nil || $0.surface == "control") })
        guard let change else { return status.control ? RemoteControlStrings.onPlain : RemoteControlStrings.offPlain }
        return changed(change, on: status.control, machine: machine, status: status) + " · " + relative(change.at)
    }

    /// "Turned on from this Mac", "Turned off on mini-7" (its own person), "Turned on from Studio".
    private func changed(_ line: RemoteControlStatus.LogLine, on: Bool, machine: JoinedMachine, status: RemoteControlStatus?) -> String {
        if line.by == "local" { return on ? RemoteControlStrings.onHere(machine.name) : RemoteControlStrings.offHere(machine.name) }
        let mac = who(line, status: status)
        return on ? RemoteControlStrings.onFrom(mac) : RemoteControlStrings.offFrom(mac)
    }

    /// The Mac a grantor line names: this Mac, else the name it gave, else its key id.
    private func who(_ line: RemoteControlStatus.LogLine, status: RemoteControlStatus?) -> String {
        if line.by == status?.selfGrantor { return RemoteControlStrings.thisMac }
        return line.name ?? line.by
    }

    private func what(_ line: RemoteControlStatus.LogLine, machine: JoinedMachine, status: RemoteControlStatus?) -> String {
        let surface = JoinConsentStrings.title(line.surface == "screen" ? .screen : .control)
        return switch line.event {
        case "grant", "revoke": surface + ": " + changed(line, on: line.event == "grant", machine: machine, status: status)
        case "refused": RemoteControlStrings.logRefused(line.by == "local" ? machine.name : who(line, status: status), reason: line.reason ?? "")
        case "pinned": RemoteControlStrings.logPinned(who(line, status: status))
        case "unpinned": RemoteControlStrings.logUnpinned(who(line, status: status))
        case "ask": RemoteControlStrings.logAsk(who(line, status: status))
        default: line.event
        }
    }

    private func relative(_ at: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: at / 1000), relativeTo: services.now())
    }

    private static func time(_ at: Double) -> String {
        DateFormatter.localizedString(from: Date(timeIntervalSince1970: at / 1000), dateStyle: .short, timeStyle: .short)
    }
}

/// Text of "Control from this Mac" (Resources/AddDevice.xcstrings).
public nonisolated struct RemoteControlStrings {
    public nonisolated init() {}
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddDevice", bundle: .module)
    }

    static var title: String { s("devices.control.groupTitle", "Control between my devices") }
    static var help: String {
        s("devices.control.groupHelp",
          "Each switch turns Control and Screen sharing on or off on one of your machines, over the switch for all your devices. A machine that has never seen this Mac asks once, on itself: allow it there only if the words it shows match this Mac's words.")
    }
    static var accountTitle: String { s("devices.control.account.title", "All my devices") }
    static var accountHelp: String {
        s("devices.control.account.help", "Your Macs and machines signed in to this account can control and share each other's screens, without asking each time.")
    }
    static var accountOn: String { s("devices.control.account.on", "On for all your devices") }
    static var accountOff: String { s("devices.control.account.off", "Off for all your devices") }
    static var refresh: String { s("devices.control.refresh", "Refresh trusted Macs") }
    static var offline: String { s("devices.state.offline", "Offline") }
    static var checking: String { s("devices.control.checking", "Checking…") }
    static var onPlain: String { s("devices.control.on", "On") }
    static var offPlain: String { s("devices.control.off", "Off") }
    /// Who turned it on or off, when it was this Mac.
    static var thisMac: String { s("devices.control.thisMac", "this Mac") }
    static func onFrom(_ mac: String) -> String { String(format: s("devices.control.onFrom", "Turned on from %@"), mac) }
    static func offFrom(_ mac: String) -> String { String(format: s("devices.control.offFrom", "Turned off from %@"), mac) }
    static func onHere(_ machine: String) -> String { String(format: s("devices.control.onHere", "Turned on on %@"), machine) }
    static func offHere(_ machine: String) -> String { String(format: s("devices.control.offHere", "Turned off on %@"), machine) }
    static func askPending(_ machine: String, words: [String]) -> String {
        String(format: s("devices.control.askPending", "Allow once on %1$@: check the words %2$@"), machine, words.joined(separator: " "))
    }
    static func logRefused(_ mac: String, reason: String) -> String {
        String(format: s("devices.control.log.refused", "Refused a change from %1$@ (%2$@)"), mac, reason)
    }
    static func logPinned(_ mac: String) -> String { String(format: s("devices.control.log.pinned", "Allowed %@ to turn Control on and off"), mac) }
    static func logUnpinned(_ mac: String) -> String { String(format: s("devices.control.log.unpinned", "Stopped allowing %@"), mac) }
    static func logAsk(_ mac: String) -> String { String(format: s("devices.control.log.ask", "%@ asked to turn Control on and off"), mac) }
    static var readFailed: String { s("devices.control.readFailed", "This Mac could not read that machine's switches. Try again.") }
    static var setFailed: String { s("devices.control.setFailed", "That machine did not take the change. Try again.") }
    static var busy: String { s("devices.join.busy", "Still saving the last change. Try again in a moment.") }
    public static var notOwned: String { s("devices.control.notOwned", "This machine is not one of yours on this account.") }
    static var signedOut: String { s("devices.control.signedOut", "This Mac is not signed in, so it can't sign a change.") }
    static var noKey: String { s("devices.control.noKey", "This Mac has no key to sign with. Try again.") }
    static func mismatch(_ machine: String) -> String {
        String(format: s("devices.control.mismatch", "Nothing changed: the machine that answered is not %@."), machine)
    }
    static func otherAccount(_ machine: String) -> String {
        String(format: s("devices.control.otherAccount", "Nothing changed: %@ is joined under another account."), machine)
    }
    /// The confirm's reason (LocalAuthentication shows it after the app's name).
    public static var confirmReason: String {
        s("devices.control.confirmReason", "turn on Control and Screen sharing on your other machine from this Mac")
    }
    public static var accountConfirmReason: String {
        s("devices.control.account.confirmReason", "turn on Control and Screen sharing between all your devices")
    }
}
