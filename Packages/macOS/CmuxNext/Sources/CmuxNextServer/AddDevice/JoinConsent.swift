public import Foundation
public import Observation
import os

/// What a joined machine's team may do on this Mac only after the person allows it here (the one-line
/// join's consent gate, contract §5). The join itself grants mesh membership alone; acpmux blocks
/// both surfaces until its consent record grants them, and the app blocks Mac Screen the same way.
public nonisolated enum JoinConsentSurface: String, CaseIterable, Equatable, Sendable {
    /// Other team machines see this screen.
    case screen
    /// Other team machines move the pointer and type here.
    case control
    /// The person's other Macs signed in to this account open workspaces and terminals here
    /// (acpmux's `signedInMachines`, which gates the cmux-tui session circuit). Asked once on this Mac,
    /// at the first New Workspace aimed at it; a sign-in alone grants nothing.
    case signedInMachines
}

/// `acpmux host join --status --json`: the parts This Mac shows. The consent comes from acpmux itself
/// (``JoinConsentRecord``), never from this line.
public nonisolated struct JoinStatus: Equatable, Sendable, Decodable {
    public var credentialPresent: Bool
    public var machineId: String?
    public var teamId: String?
    /// The team's name when the status carries one; else the page shows ``teamId``.
    public var teamName: String?
    /// The machine's name in the team; else the page shows ``machineId``.
    public var name: String?
    public var revoked: Bool

    public init(credentialPresent: Bool, machineId: String? = nil, teamId: String? = nil, teamName: String? = nil,
                name: String? = nil, revoked: Bool = false) {
        self.credentialPresent = credentialPresent
        self.machineId = machineId
        self.teamId = teamId
        self.teamName = teamName
        self.name = name
        self.revoked = revoked
    }

    private enum Keys: String, CodingKey { case credentialPresent, machineId, teamId, teamName, name, revoked }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        credentialPresent = try c.decodeIfPresent(Bool.self, forKey: .credentialPresent) ?? false
        machineId = try c.decodeIfPresent(String.self, forKey: .machineId)
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId)
        teamName = try c.decodeIfPresent(String.self, forKey: .teamName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
    }

    public static func parse(_ data: Data) -> JoinStatus? { try? JSONDecoder().decode(JoinStatus.self, from: data) }
}

/// acpmux's consent record (`_acpmux/machine_consent_get`, and `_acpmux/machine_consent_set`'s answer):
/// `{"consent": {"screen": "none"|"granted", "control": …}, "lastRefusal": {…, "surface": …} | null}`.
public nonisolated struct JoinConsentRecord: Equatable, Sendable {
    public var screen: Bool
    public var control: Bool
    /// The surface of the last request acpmux refused with `consent_required`; nil when none.
    public var lastRefusal: JoinConsentSurface?
    /// acpmux's `consentRequired`: this machine is joined, so its surfaces need consent; nil from an
    /// acpmux that does not send it.
    public var consentRequired: Bool?
    /// The person's other Macs signed in to this account may open workspaces here (`signedInMachines`).
    public var signedInMachines: Bool
    /// The machine that asked last, as acpmux recorded it (`lastRefusal.from`, a host the hub lists).
    public var lastRefusalFrom: String?
    /// The last refusal is a `signedInMachines` ask nobody answered since acpmux recorded it: acpmux
    /// records that ask only while this Mac's account has no answer, and any answer (Allow, Not now, a
    /// later Off) comes after it.
    public var signedInMachinesAskOpen: Bool
    /// When acpmux recorded the last refusal, a `signedInMachines` one (its milliseconds); nil otherwise.
    public var lastRefusalAt: Double?
    /// The one pending ask of another Mac of the person's to have its key trusted here (`grantorAsk`): its
    /// first signed Control grant left it. nil: none.
    public var grantorAsk: JoinConsentGrantor?
    /// The Macs whose keys this machine trusts to turn its Control and Screen sharing on and off (`grantors`).
    public var grantors: [JoinConsentGrantor]
    /// The account this machine is enrolled under (`account`), which an account-wide grant names.
    public var account: String?
    /// The newest account-wide grant this machine took (`accountPolicy`); nil: none.
    public var accountPolicy: AccountPolicy?
    /// acpmux reports `accountPolicy` at all, null included: it takes account-wide grants.
    public var reportsAccountPolicy = false

    /// What an account-wide grant turns on for every machine of the account (contract v2 A).
    public struct AccountPolicy: Equatable, Sendable {
        public var grantor: String
        public var issuedAt: Double
        public var control: Bool
        public var screen: Bool

        init?(_ json: Any?) {
            guard let json = json as? [String: Any], let grantor = json["grantor"] as? String else { return nil }
            let on = { (value: Any?) in value as? Bool == true || value as? String == "on" }
            self.init(grantor: grantor, issuedAt: (json["issuedAt"] as? NSNumber)?.doubleValue ?? 0, control: on(json["control"]),
                      screen: on(json["screen"]))
        }

        public init(grantor: String, issuedAt: Double, control: Bool, screen: Bool) {
            self.grantor = grantor
            self.issuedAt = issuedAt
            self.control = control
            self.screen = screen
        }
    }

    public init(screen: Bool = false, control: Bool = false, lastRefusal: JoinConsentSurface? = nil, consentRequired: Bool? = nil,
                signedInMachines: Bool = false, lastRefusalFrom: String? = nil, signedInMachinesAskOpen: Bool = false,
                lastRefusalAt: Double? = nil, grantorAsk: JoinConsentGrantor? = nil, grantors: [JoinConsentGrantor] = []) {
        self.screen = screen
        self.control = control
        self.lastRefusal = lastRefusal
        self.consentRequired = consentRequired
        self.signedInMachines = signedInMachines
        self.lastRefusalFrom = lastRefusalFrom
        self.signedInMachinesAskOpen = signedInMachinesAskOpen
        self.lastRefusalAt = lastRefusalAt
        self.grantorAsk = grantorAsk
        self.grantors = grantors
    }

    /// The record in a result; nil without a `consent` object. Only the word `granted` is on.
    public static func parse(_ result: [String: Any]) -> JoinConsentRecord? {
        guard let consent = result["consent"] as? [String: Any] else { return nil }
        let refusal = result["lastRefusal"] as? [String: Any]
        let surface = (refusal?["surface"] as? String).flatMap(JoinConsentSurface.init(rawValue:))
        let from = (refusal?["from"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(128)) }
        // Both times are acpmux's milliseconds: the refusal's a number, the answer's a string.
        let askedAt = (refusal?["at"] as? NSNumber)?.doubleValue
        let answeredAt = (consent["signedInMachinesAnsweredAt"] as? String).flatMap(Double.init)
        let open = surface == .signedInMachines && askedAt.map { asked in answeredAt.map { $0 < asked } ?? true } == true
        var record = JoinConsentRecord(screen: consent["screen"] as? String == "granted", control: consent["control"] as? String == "granted",
                                       lastRefusal: surface, consentRequired: result["consentRequired"] as? Bool,
                                       signedInMachines: consent["signedInMachines"] as? String == "granted", lastRefusalFrom: from,
                                       signedInMachinesAskOpen: open, lastRefusalAt: surface == .signedInMachines ? askedAt : nil,
                                       grantorAsk: (result["grantorAsk"] as? [String: Any]).flatMap { JoinConsentGrantor($0) },
                                       grantors: Array((result["grantors"] as? [[String: Any]] ?? []).compactMap { JoinConsentGrantor($0) }.prefix(16)))
        record.account = (result["account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        record.accountPolicy = AccountPolicy(result["accountPolicy"])
        record.reportsAccountPolicy = result.keys.contains("accountPolicy")
        return record
    }

    public func allows(_ surface: JoinConsentSurface) -> Bool {
        switch surface {
        case .screen: screen
        case .control: control
        case .signedInMachines: signedInMachines
        }
    }
}

/// Another Mac of the person's, by the key it signs Control grants with (acpmux `grantors.json` and
/// `grantor-ask.json`, as `machine_consent_get` reports them): a trusted one, or the pending ask.
public nonisolated struct JoinConsentGrantor: Equatable, Sendable {
    /// `mac-` and 16 hex digits of the key's hash.
    public var id: String
    /// The name the Mac gave (not signed: a hint only); nil when it gave none.
    public var name: String?
    /// The key's four words (acpmux `fingerprint_words`), which the person matches with the ones that Mac shows.
    public var words: [String]
    /// Where the ask came from (a host the hub lists); asks only.
    public var from: String?
    /// When it was trusted, or asked (acpmux's milliseconds).
    public var at: Double?

    public init(id: String, name: String? = nil, words: [String] = [], from: String? = nil, at: Double? = nil) {
        self.id = id
        self.name = name
        self.words = words
        self.from = from
        self.at = at
    }

    /// One entry of `grantors` (`pinnedAt`) or the `grantorAsk` (`at`, `from`); nil without an id.
    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let text = { (key: String) -> String? in (json[key] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(128)) } }
        let time = { (key: String) -> Double? in
            if let number = json[key] as? NSNumber, !(json[key] is Bool) { return number.doubleValue }
            return (json[key] as? String).flatMap(Double.init)
        }
        self.init(id: String(id.prefix(64)), name: text("name"), words: Array((json["words"] as? [String] ?? []).prefix(4).map { String($0.prefix(32)) }),
                  from: text("from"), at: time("pinnedAt") ?? time("at"))
    }

    /// What the person reads: its name, else its id.
    var title: String { name ?? id }
}

/// One connection to this Mac's acpmux for the consent record (the app's ``AcpmuxPersonLine``). acpmux
/// changes it only for a connection proven as the person, as `_acpmux/pair_set`'s Full access does.
@MainActor
public protocol JoinConsentLine: AnyObject {
    var isPerson: Bool { get }
    /// acpmux announced `machine-consent-v1`: it keeps the record and answers the two calls below.
    var supportsConsent: Bool { get }
    /// `_acpmux/machine_consent_get`; nil when it failed.
    func read() async -> JoinConsentRecord?
    /// `_acpmux/machine_consent_set`: the record acpmux holds after it, nil when it did not take it.
    /// SECURITY: a grant comes with its `ticket`, and the line writes its bytes only through
    /// ``JoinConsentGrantTicket/write(_:)``, on the queue that writes the socket; a stale ticket sends
    /// nothing and answers nil. A revoke has none.
    func set(_ surface: JoinConsentSurface, granted: Bool, ticket: JoinConsentGrantTicket?) async -> JoinConsentRecord?
    /// Any other request of the consent surface (`_acpmux/consent_grantor_trust`, `_acpmux/consent_remote_*`):
    /// its `result`, or acpmux's own words for a refusal (nil words: no answer).
    func call(_ method: String, _ params: [String: Any]) async -> Result<[String: Any], RemoteControlCallError>
    func close()
}

extension JoinConsentLine {
    /// A line that serves only the record (a capture fixture): every other request fails.
    public func call(_ method: String, _ params: [String: Any]) async -> Result<[String: Any], RemoteControlCallError> {
        .failure(RemoteControlCallError(nil))
    }
}

/// SECURITY: what makes a grant stale where its bytes go out (round 15 P1). A grant takes a ticket when it
/// starts; the Labs switch moving or a settings load invalidates every older one, and the line writes a
/// grant only through ``JoinConsentGrantTicket/write(_:)``, which checks the ticket and writes under one
/// lock. So once ``invalidate()`` returns, no older grant reaches acpmux: it was either out before (the
/// lock waited for its write) or is never sent.
public nonisolated final class JoinConsentGrantGate: Sendable {
    private let epoch = OSAllocatedUnfairLock(initialState: 0)

    public init() {}

    /// The ticket a grant takes when it starts.
    public func ticket() -> JoinConsentGrantTicket {
        JoinConsentGrantTicket(gate: self, epoch: epoch.withLock { $0 })
    }

    /// Every ticket taken before this is stale. Waits for a grant being written with one (a few hundred
    /// bytes to a local socket), never for acpmux's answer.
    public func invalidate() {
        epoch.withLock { $0 += 1 }
    }

    fileprivate func write(_ ticket: Int, _ bytes: () -> Void) -> Bool {
        epoch.withLockUnchecked { epoch in
            guard epoch == ticket else { return false }
            bytes()
            return true
        }
    }
}

/// One grant's ticket (``JoinConsentGrantGate``).
public nonisolated struct JoinConsentGrantTicket: Sendable {
    let gate: JoinConsentGrantGate
    let epoch: Int

    /// Runs `bytes` (the socket write of the grant) only while the ticket is current, holding the gate's
    /// lock while it runs. False when it was stale: nothing was written.
    public func write(_ bytes: () -> Void) -> Bool {
        gate.write(epoch, bytes)
    }
}

/// A request acpmux refused with `consent_required`: a team machine's screen or control, or one of the person's
/// other Macs asking to open a workspace here (`signedInMachines`).
public nonisolated struct JoinConsentRefusal: Equatable, Sendable {
    public var requester: String
    public var surface: JoinConsentSurface

    public init(requester: String, surface: JoinConsentSurface) {
        self.requester = requester
        self.surface = surface
    }
}

/// The device owner's answer to a grant's confirm (Touch ID or the login password).
public enum JoinConsentConfirm: Sendable {
    case confirmed
    /// The person cancelled, or the check failed.
    case cancelled
    /// This Mac can't ask (no login password, a policy error): nothing is granted.
    case unavailable
}

/// What the consent gate asks of the app, so tests run it with fakes. Every call runs on the main actor.
public struct JoinConsentServices {
    /// `acpmux host join --status --json`; nil when this Mac is not joined or the run failed.
    public var status: @MainActor () async -> JoinStatus?
    /// A person-proof line to this Mac's acpmux; nil when no acpmux answers.
    public var openLine: @MainActor () async -> (any JoinConsentLine)?
    /// `labs.machineJoin`.
    public var enabled: @MainActor () -> Bool
    /// Moves on every settings load (`SettingsController.loadCount`): a grant is sent only when no load
    /// came since it started, so the Labs switch turned off and on again in between (which no observer
    /// may see, since observation coalesces) drops it.
    public var settingsEpoch: @MainActor () -> Int
    /// SECURITY: the device owner confirms a grant of `surface` (LocalAuthentication
    /// `deviceOwnerAuthentication`) before it is sent. Default: unavailable, so nothing is granted.
    public var confirmOwner: @MainActor (JoinConsentSurface) async -> JoinConsentConfirm
    /// The one-time sheet already showed on this Mac (kept across launches).
    public var askShown: @MainActor () -> Bool
    public var markAskShown: @MainActor () -> Void

    public init(status: @escaping @MainActor () async -> JoinStatus?, openLine: @escaping @MainActor () async -> (any JoinConsentLine)?,
                enabled: @escaping @MainActor () -> Bool, settingsEpoch: @escaping @MainActor () -> Int = { 0 },
                confirmOwner: @escaping @MainActor (JoinConsentSurface) async -> JoinConsentConfirm = JoinConsentServices.cannotConfirm,
                askShown: @escaping @MainActor () -> Bool, markAskShown: @escaping @MainActor () -> Void) {
        self.status = status
        self.openLine = openLine
        self.enabled = enabled
        self.settingsEpoch = settingsEpoch
        self.confirmOwner = confirmOwner
        self.askShown = askShown
        self.markAskShown = markAskShown
    }

    /// The default confirm: this Mac can't ask, so nothing is granted. A named function, not a closure
    /// literal default (an async closure default is a crash class, cx-bsue).
    @MainActor
    public static func cannotConfirm(_ surface: JoinConsentSurface) async -> JoinConsentConfirm {
        .unavailable
    }
}

/// This Mac's join consent: the switches of Settings > Devices, the one-time sheet on the first
/// refused request, and Mac Screen's gate. Turning a switch on needs a line acpmux proved as the person
/// (``JoinConsentLine/isPerson``). It reads only when asked (Settings opening, the app coming forward,
/// a write, a Mac Screen ticket).
///
/// One serial owner: the model is the only holder of consent state, and every read, write, ticket and
/// press runs through it on the main actor. Each one takes the next generation when it starts; a result
/// is applied only while its generation is still the newest, and an older one is dropped.
/// SECURITY: fail closed. Mac Screen serves only on an explicit `granted` from the read of the current
/// generation, and as "not joined" only on acpmux's explicit `consentRequired: false`. An error, a
/// missing capability, a dropped read or a write in flight never allows.
@MainActor @Observable
public final class JoinConsentModel {
    public private(set) var status: JoinStatus?
    /// acpmux's record, as the switches show it; nil before the first read, when the read failed, or when
    /// acpmux has no record. After a write whose own read failed, the record acpmux answered the write with.
    public private(set) var consent: JoinConsentRecord?
    /// SECURITY: the record of the last applied read that got through, narrowed by a revoke the moment it
    /// starts. Only this gates Mac Screen; the record a write answered with never does.
    @ObservationIgnored private var verified: JoinConsentRecord?
    /// This Mac's acpmux has `machine-consent-v1` (without it nothing is granted); nil when none answered.
    public private(set) var consentSupported: Bool?
    /// Why the last write failed; nil after a success.
    public private(set) var lastError: String?
    /// The refused request the one-time sheet shows; nil while it is hidden.
    public private(set) var ask: JoinConsentRefusal?
    /// Why the sheet's Allow did not take; the sheet stays up showing it.
    public private(set) var askError: String?
    /// A write is in flight: the switches and the sheet's buttons are disabled, another write or press
    /// does nothing, and no Mac Screen ticket is allowed until it ends.
    public private(set) var writing = false
    /// Shows and hides the sheet; the app sets the panel, tests record it.
    @ObservationIgnored public var present: @MainActor (Bool) -> Void = { _ in }
    /// Redraws a showing sheet (its buttons follow ``writing``).
    @ObservationIgnored public var redraw: @MainActor () -> Void = {}
    /// After each change applied: the app stops a Mac Screen session the consent no longer allows.
    @ObservationIgnored public var changed: @MainActor () -> Void = {}
    /// SECURITY: a capture fixture stands in for this Mac's join (the app's DEBUG `debug.join_consent`), so the
    /// app's Mac Screen gate never authorizes a live session. Always false in a Release build.
    @ObservationIgnored public var fixtureActive: @MainActor () -> Bool = { false }
    @ObservationIgnored private let services: JoinConsentServices
    /// Invalidated by ``featureSwitched()`` and, in the app, by every settings load as it happens.
    public nonisolated let grantGate = JoinConsentGrantGate()
    /// The newest request's generation; only its result is applied.
    @ObservationIgnored private(set) var generation = 0
    /// A read was asked for while a write was in flight (and dropped): the write reads again before it
    /// ends, so a change acpmux made meanwhile is never lost behind the write's own read.
    @ObservationIgnored private var askedDuringWrite = false
    /// The `signedInMachines` ask (acpmux's refusal time) the sheet already showed: it shows again only for
    /// a newer ask, so a Not now whose write failed doesn't bring it back on every read.
    @ObservationIgnored private var shownSignedInAsk: Double?

    /// What the app follows for the model (the Labs switch, acpmux's folder); cancelled with the model.
    @ObservationIgnored public var following: Task<Void, Never>? {
        willSet { following?.cancel() }
    }

    public init(services: JoinConsentServices) {
        self.services = services
    }

    nonisolated deinit { following?.cancel() }

    /// The Labs switch (`labs.machineJoin`).
    public var enabled: Bool { services.enabled() }

    /// The switches show: the Labs switch is on and this Mac holds a join credential that is not revoked.
    public var shown: Bool { services.enabled() && status?.credentialPresent == true && status?.revoked != true }

    /// One read: the join status and acpmux's record.
    private struct Reading {
        var status: JoinStatus?
        var consent: JoinConsentRecord?
        var supported: Bool?
    }

    public func refresh() async {
        _ = await read()
    }

    /// The Labs switch turned on or off: what was read before no longer counts, then it reads.
    public func featureChanged() async {
        featureSwitched()
        await refresh()
    }

    /// The Labs switch turned on or off, at once and without waiting on acpmux: what was read before no
    /// longer counts, nothing is allowed until the next read (a running Mac Screen session stops when the
    /// switch turns on), a grant still on its way is never sent, and with it off an open sheet closes.
    public func featureSwitched() {
        grantGate.invalidate()
        generation += 1
        status = nil
        consent = nil
        verified = nil
        consentSupported = nil
        changed()
        if !enabled, ask != nil { dismissAsk() }
    }

    private enum ReadKind {
        /// A refresh or a ticket's own read.
        case plain
        /// The write's check before it sends: never applied.
        case writeCheck
        /// The write's own read after it lands.
        case afterWrite
    }

    /// Takes the next generation and reads. The result is applied, and `current` is true, only while no
    /// newer request started meanwhile and no write is in flight (a write's own read after it lands
    /// excepted); the reading comes back either way. A read started during a write takes no generation,
    /// so it never displaces the write's own read; the write reads once more for it before it ends.
    private func read(_ kind: ReadKind = .plain) async -> (reading: Reading, current: Bool) {
        let duringWrite = writing && kind != .afterWrite
        if duringWrite, kind == .plain { askedDuringWrite = true }
        if !duringWrite { generation += 1 }
        let mine = generation
        var reading = Reading()
        if services.enabled() {
            reading.status = await services.status()
            if let line = await services.openLine() {
                reading.supported = line.supportsConsent
                if line.supportsConsent { reading.consent = await line.read() }
                line.close()
            }
        }
        guard !duringWrite, mine == generation, kind == .afterWrite || !writing else { return (reading, false) }
        apply(reading)
        return (reading, true)
    }

    private func apply(_ reading: Reading) {
        status = reading.status
        consent = reading.consent
        verified = reading.consent
        consentSupported = reading.supported
        changed()
        // The Labs switch went off, or the join went away or was revoked (said so, not merely unread): an
        // open sheet can no longer allow.
        let gone = !enabled || reading.status?.credentialPresent == false || reading.status?.revoked == true
        if gone, ask != nil { dismissAsk() }
        // acpmux refused a team machine for a surface still off: the first such refusal shows the sheet.
        // One of the person's other Macs asking for a workspace shows it while that ask is unanswered
        // (acpmux keeps the answer), naming the Mac when acpmux recorded it, unless the sheet already
        // showed that ask here.
        if shown, let record = reading.consent, let surface = record.lastRefusal, !record.allows(surface) {
            if surface == .signedInMachines {
                if record.signedInMachinesAskOpen, record.lastRefusalAt != shownSignedInAsk,
                   refused(JoinConsentRefusal(requester: record.lastRefusalFrom ?? JoinConsentStrings.otherMac, surface: surface)) {
                    shownSignedInAsk = record.lastRefusalAt
                }
            } else {
                refused(JoinConsentRefusal(requester: JoinConsentStrings.teamMachine, surface: surface))
            }
        }
    }

    /// Turns `surface` on or off on this Mac. Returns the error to show, nil when set.
    @discardableResult
    public func set(_ surface: JoinConsentSurface, on: Bool) async -> String? {
        guard !writing else { return JoinConsentStrings.busy }
        setWriting(true)
        defer { setWriting(false) }
        generation += 1
        askedDuringWrite = false
        // Nothing but the Labs switch moves the generation while a write is in flight (reads then take
        // none, tickets are refused, another write is busy): a grant is sent only at its own, and only
        // when no settings load came since it started.
        let mine = generation, epoch = services.settingsEpoch(), ticket = grantGate.ticket()
        if !on {
            // SECURITY: a revoke narrows at once, before acpmux answers: a running session stops now, and
            // no read that started before it (which may say granted) is applied. Its "not joined" goes too
            // (a join may have come since that read).
            consent = consent.map { Self.narrowed($0, surface) }
            verified = verified.map { Self.narrowed($0, surface) }
            changed()
        }
        let written: JoinConsentRecord?
        (lastError, written) = await write(surface, on: on, generation: mine, epoch: epoch, ticket: ticket)
        // What acpmux holds now, whichever way the write went; reads made meanwhile are never applied,
        // and when one was asked for, this reads again (until none was), so its news is not lost.
        var (reading, current) = await read(.afterWrite)
        while askedDuringWrite {
            askedDuringWrite = false
            (reading, current) = await read(.afterWrite)
        }
        // When that read fails, the switches show the record acpmux answered the write with; Mac Screen
        // still has nothing it may serve on until a read gets through.
        if current, enabled, reading.consent == nil, let written {
            consent = written
            changed()
        }
        // The surface the open sheet asks for was granted (from Settings, or by its own Allow): nothing is
        // left to ask.
        if on, lastError == nil, ask?.surface == surface { dismissAsk() }
        return lastError
    }

    private static func narrowed(_ record: JoinConsentRecord, _ surface: JoinConsentSurface) -> JoinConsentRecord {
        var record = record
        switch surface {
        case .screen: record.screen = false
        case .control: record.control = false
        case .signedInMachines: record.signedInMachines = false
        }
        record.consentRequired = nil
        return record
    }

    /// The write itself: the error to show (nil when acpmux took it) and the record acpmux answered with.
    private func write(_ surface: JoinConsentSurface, on: Bool, generation mine: Int, epoch: Int,
                       ticket: JoinConsentGrantTicket) async -> (String?, JoinConsentRecord?) {
        let failed = on ? JoinConsentStrings.onFailed : JoinConsentStrings.offFailed
        if on {
            // An on only for a joined, unrevoked Mac with the Labs switch on, as this read finds it (acpmux
            // checks the person itself; this keeps a grant off a Mac that shows no switches).
            let (reading, _) = await read(.writeCheck)
            guard enabled, reading.status?.credentialPresent == true, reading.status?.revoked != true else { return (failed, nil) }
            // SECURITY: the device owner confirms every grant (Touch ID or the login password), whatever the
            // input that asked for it: an event's source fields can be forged by a process allowed to post
            // events, and a posted event can't pass this. The person-input checks before it only refuse
            // early; they never grant on their own. A Labs change or settings load meanwhile still drops
            // the grant (checked again below).
            switch await services.confirmOwner(surface) {
            case .confirmed: break
            case .cancelled: return (failed, nil)
            case .unavailable: return (JoinConsentStrings.confirmUnavailable, nil)
            }
        }
        guard let line = await services.openLine() else { return (failed, nil) }
        defer { line.close() }
        // SECURITY: only the person at this Mac turns a surface on (acpmux also takes a revoke only from
        // the person's connection; the page asks no gesture for one, since it narrows).
        if on, !line.isPerson { return (failed, nil) }
        guard line.supportsConsent else { return (on ? JoinConsentStrings.unsupported : failed, nil) }
        // The Labs switch may have turned off (and on again) while the line opened: a grant is sent only
        // at its own generation, with the switch on and no settings load since it started. The line checks
        // the ticket once more as it writes, since either can change after this check.
        if on, !enabled || generation != mine || services.settingsEpoch() != epoch { return (failed, nil) }
        let written = await line.set(surface, granted: on, ticket: on ? ticket : nil)
        return (written == nil ? failed : nil, written)
    }

    /// Trusts (or stops trusting) another Mac's key to turn this machine's Control and Screen sharing on
    /// and off: the pending ask's Allow (`trusted`), its Not Now, or a trusted Mac's Remove (both false).
    /// The error to show, or nil. Reads again after, whichever way it went.
    /// SECURITY: a trust widens, so only over a line acpmux proved as the person, with the Labs switch on
    /// and this Mac joined; the page asked the person's own HID gesture and Touch ID or the password before
    /// this. acpmux checks the person itself and pins only its own pending ask's key for the current
    /// account. An untrust only narrows.
    @discardableResult
    public func trustGrantor(_ id: String, trusted: Bool) async -> String? {
        let failed = trusted ? JoinConsentStrings.grantorTrustFailed : JoinConsentStrings.offFailed
        guard !id.isEmpty else { return failed }
        if trusted, !shown { return failed }
        guard let line = await services.openLine() else { return failed }
        var taken = false
        if !trusted || (line.isPerson && enabled), line.supportsConsent {
            if case .success = await line.call("_acpmux/consent_grantor_trust", ["id": id, "trusted": trusted]) { taken = true }
        }
        line.close()
        await refresh()
        return taken ? nil : failed
    }

    /// One request over a line acpmux proved as the person (Control from this Mac's status and sets): its
    /// result, or the error to show (nil words: no answer). Nothing goes out over a line that is not the person's.
    public func personCall(_ method: String, _ params: [String: Any]) async -> Result<[String: Any], RemoteControlCallError> {
        guard let line = await services.openLine() else { return .failure(RemoteControlCallError(nil)) }
        defer { line.close() }
        guard line.isPerson else { return .failure(RemoteControlCallError(nil)) }
        return await line.call(method, params)
    }

    private func setWriting(_ on: Bool) {
        writing = on
        if ask != nil { redraw() }
    }

    /// What the last applied read that got through allows a running Mac Screen session (no such read,
    /// nothing; a write's answer never counts). With the Labs
    /// switch off, everything, as before. With it on: a Mac acpmux reports not joined
    /// (`consentRequired: false`) serves as before, which is acpmux's own rule; any other serves View
    /// Only with Screen sharing granted and Full Control with Control granted too.
    public func permitsMacScreen(control: Bool) -> Bool {
        guard services.enabled() else { return true }
        return Self.permits(Reading(status: status, consent: verified, supported: consentSupported), control: control)
    }

    private static func permits(_ reading: Reading, control: Bool) -> Bool {
        guard reading.supported == true, let consent = reading.consent else { return false }
        if consent.consentRequired == false { return true }
        return consent.screen && (!control || consent.control)
    }

    /// The reading says this Mac is joined (acpmux's word first, else the join status): only then does a
    /// refusal show the sheet, since an unjoined Mac has nothing to allow.
    private static func joined(_ reading: Reading) -> Bool {
        (reading.consent?.consentRequired ?? reading.status?.credentialPresent) == true
    }

    /// Mac Screen asks before it serves a session: the app owns it, so acpmux's gate never sees it. The
    /// ticket takes the next generation and reads; it serves only when that read is still the newest when
    /// it answers, allows it, and no write is in flight. A refusal on a Mac read as joined shows the sheet:
    /// read from acpmux's record that got through, or from the join status on an acpmux without the consent
    /// capability (which has granted nothing). A record that failed to read refuses without the sheet.
    public func allowsMacScreen(control: Bool, requester: String) async -> Bool {
        guard services.enabled() else { return true }
        guard !writing else { return false }
        let (reading, current) = await read()
        guard current, !writing else { return false }
        if Self.permits(reading, control: control) { return true }
        if reading.supported == false || reading.consent != nil, Self.joined(reading) {
            refused(JoinConsentRefusal(requester: requester, surface: reading.consent?.screen == true ? .control : .screen))
        }
        return false
    }

    /// acpmux refused a team machine's request with `consent_required`: the first one on this Mac
    /// shows the sheet, once. Later ones, or any while the Labs switch is off, show nothing. A
    /// `signedInMachines` ask is asked once by acpmux, which keeps its answer per account, so it does not
    /// take or spend this Mac's one screen-or-control ask. True when the sheet showed it.
    @discardableResult
    public func refused(_ refusal: JoinConsentRefusal) -> Bool {
        let once = refusal.surface != .signedInMachines
        guard services.enabled(), ask == nil, !once || !services.askShown() else { return false }
        if once { services.markAskShown() }
        ask = refusal
        askError = nil
        present(true)
        return true
    }

    /// The sheet's Deny or Allow. Allow writes through the same person path as the switch; when it does
    /// not take, the sheet stays up with the reason. While a write is in flight both buttons are disabled
    /// and a press does nothing, so a Deny never closes the sheet over a grant still landing. Not now on a
    /// `signedInMachines` ask closes the sheet at once and writes the answer (off), so acpmux asks no more.
    @discardableResult
    public func answer(allow: Bool) async -> String? {
        guard let refusal = ask, !writing else { return nil }
        guard allow, services.enabled() else {
            dismissAsk()
            if refusal.surface == .signedInMachines, services.enabled() { return await set(.signedInMachines, on: false) }
            return nil
        }
        if let error = await set(refusal.surface, on: true) {
            guard ask == refusal else { return error }
            askError = error
            present(true)
            return error
        }
        // The grant closed it already (``set(_:on:)``).
        if ask != nil { dismissAsk() }
        return nil
    }

    private func dismissAsk() {
        ask = nil
        askError = nil
        present(false)
    }

    /// Settings > Devices' join block (`devices_join` in the host lists); nil while it does not show.
    public func pageData() -> Data? {
        guard shown, let status else { return nil }
        let team = status.teamName ?? status.teamId ?? ""
        let name = status.name ?? status.machineId ?? ""
        let page = JoinConsentPage(
            title: JoinConsentStrings.section, joined: JoinConsentStrings.joined(team: team, name: name), help: JoinConsentStrings.help,
            error: lastError ?? (consentSupported == false ? JoinConsentStrings.unsupported : consent == nil ? JoinConsentStrings.unread : nil),
            busy: writing,
            known: consentSupported == true && consent != nil,
            revokeAll: consentSupported == true && consent != nil ? nil : JoinConsentStrings.revokeAll,
            switches: JoinConsentSurface.allCases.map {
                JoinConsentPage.Switch(surface: $0.rawValue, title: JoinConsentStrings.title($0), help: JoinConsentStrings.switchHelp($0),
                                       on: consent?.allows($0) == true)
            },
            grantorAsk: consent?.grantorAsk.map { ask in
                JoinConsentPage.GrantorAsk(id: ask.id, title: JoinConsentStrings.grantorAskTitle(ask.title),
                                           help: JoinConsentStrings.grantorAskHelp(ask.title), words: ask.words,
                                           allow: JoinConsentStrings.grantorAllow, dismiss: JoinConsentStrings.grantorDismiss)
            },
            grantors: (consent?.grantors ?? []).map { grantor in
                JoinConsentPage.Grantor(id: grantor.id, title: grantor.title,
                                        subtitle: JoinConsentStrings.grantorSubtitle(words: grantor.words),
                                        remove: JoinConsentStrings.grantorRemove)
            })
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try? encoder.encode(page)
    }
}

/// The JSON shape of ``JoinConsentModel/pageData()``.
private nonisolated struct JoinConsentPage: Encodable {
    struct Switch: Encodable {
        var surface, title, help: String
        var on: Bool
    }

    /// Another Mac of the person's asks to have its key trusted here (its first signed Control grant).
    struct GrantorAsk: Encodable {
        var id, title, help: String
        var words: [String]
        var allow, dismiss: String
    }

    /// A Mac whose key this machine trusts, with its Remove.
    struct Grantor: Encodable {
        var id, title, subtitle, remove: String
    }

    var title, joined, help: String
    var error: String?
    /// A write is in flight: the page disables the switches.
    var busy: Bool
    /// acpmux's record is known (read, or a write's answer): without it the page disables the switches,
    /// which would otherwise show an off nobody confirmed.
    var known: Bool
    /// While the record is unknown, the label of the action that turns both off (off always works); nil
    /// while it is known.
    var revokeAll: String?
    var switches: [Switch]
    /// The pending key ask, `null` when none (always sent, so the page clears it).
    var grantorAsk: GrantorAsk?
    var grantors: [Grantor]

    private enum CodingKeys: String, CodingKey {
        case title, joined, help, error, busy, known, revokeAll, switches, grantorAsk, grantors
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(joined, forKey: .joined)
        try c.encode(help, forKey: .help)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(busy, forKey: .busy)
        try c.encode(known, forKey: .known)
        try c.encodeIfPresent(revokeAll, forKey: .revokeAll)
        try c.encode(switches, forKey: .switches)
        try c.encode(grantorAsk, forKey: .grantorAsk)
        try c.encode(grantors, forKey: .grantors)
    }
}

/// Text of the join consent (Resources/AddDevice.xcstrings).
public nonisolated struct JoinConsentStrings {
    public nonisolated init() {}
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddDevice", bundle: .module)
    }

    static var section: String { s("devices.join.section", "This Mac on Your Team") }
    static func joined(team: String, name: String) -> String {
        String(format: s("devices.join.joined", "Joined to %1$@ as %2$@"), team, name)
    }
    static var help: String {
        s("devices.join.help", "Your team's machines reach this Mac through the mesh. They cannot see or control it until you allow it here.")
    }
    static func title(_ surface: JoinConsentSurface) -> String {
        switch surface {
        case .screen: s("devices.join.screen", "Screen sharing")
        case .control: s("devices.join.control", "Control")
        case .signedInMachines: s("devices.join.signedInMachines", "Your other Macs")
        }
    }
    static func switchHelp(_ surface: JoinConsentSurface) -> String {
        switch surface {
        case .screen: s("devices.join.screenHelp", "Your team's machines can see this screen")
        case .control: s("devices.join.controlHelp", "Your team's machines can move the pointer and type here")
        case .signedInMachines: s("devices.join.signedInMachinesHelp", "Your other Macs signed in to this account can open workspaces and terminals here")
        }
    }
    static var onFailed: String { s("devices.join.onFailed", "Still off: this Mac could not confirm it was you") }
    static var confirmUnavailable: String {
        s("devices.join.confirmUnavailable", "Still off: this Mac can't ask for Touch ID or your login password, so it can't confirm it's you.")
    }
    /// The confirm's reason (LocalAuthentication shows it after the app's name).
    public static func confirmReason(_ surface: JoinConsentSurface) -> String {
        switch surface {
        case .screen: s("devices.join.confirm.screen", "allow your team's machines to see this Mac's screen")
        case .control: s("devices.join.confirm.control", "allow your team's machines to control this Mac")
        case .signedInMachines: s("devices.join.confirm.signedInMachines", "allow your other Macs signed in to this account to open workspaces on this Mac")
        }
    }
    static var offFailed: String { s("devices.join.offFailed", "It could not be turned off. Try again.") }
    static var unread: String {
        s("devices.join.unread", "This Mac could not read what it allows, so Mac Screen is refused until it can. The switches come back when it reads again.")
    }
    static var busy: String { s("devices.join.busy", "Still saving the last change. Try again in a moment.") }
    static var revokeAll: String { s("devices.join.revokeAllSurfaces", "Turn All Off") }
    static var unsupported: String { s("devices.join.unsupported", "Still off: this Mac's cmux needs an update before you can allow this") }
    /// Who asked, when acpmux recorded only the refusal.
    static var teamMachine: String { s("devices.join.ask.teamMachine", "A machine on your team") }
    /// Who asked for a workspace, when acpmux did not record which Mac.
    static var otherMac: String { s("devices.join.ask.otherMac", "One of your other Macs") }

    // The one-time sheet.
    static func askTitle(_ refusal: JoinConsentRefusal) -> String {
        switch refusal.surface {
        case .screen: String(format: s("devices.join.ask.screen", "%@ asked to see this screen."), refusal.requester)
        case .control: String(format: s("devices.join.ask.control", "%@ asked to control this Mac."), refusal.requester)
        case .signedInMachines:
            String(format: s("devices.join.ask.signedInMachines", "%@ asked to open a workspace on this Mac."), refusal.requester)
        }
    }
    static func askQuestion(_ surface: JoinConsentSurface) -> String {
        switch surface {
        case .screen: s("devices.join.ask.screenQuestion", "Allow screen sharing from your team's machines?")
        case .control: s("devices.join.ask.controlQuestion", "Allow control from your team's machines?")
        case .signedInMachines: s("devices.join.ask.signedInMachinesQuestion", "Allow your other Macs signed in to this account to open workspaces here?")
        }
    }
    static var askNote: String { s("devices.join.ask.note", "You can change this later in Settings > Devices.") }
    static var deny: String { s("devices.join.ask.deny", "Deny") }
    /// The sheet's decline: Not now for a workspace ask (it is answered once), Deny otherwise.
    static func decline(_ surface: JoinConsentSurface) -> String {
        surface == .signedInMachines ? s("devices.join.ask.notNow", "Not now") : deny
    }
    static var allow: String { s("devices.join.ask.allow", "Allow") }

    // Another Mac of the person's asks to turn this machine's Control on and off (a signed grant).
    static func grantorAskTitle(_ mac: String) -> String {
        String(format: s("devices.join.grantor.askTitle", "%@ asks to turn Control on and off here"), mac)
    }
    static func grantorAskHelp(_ mac: String) -> String {
        String(format: s("devices.join.grantor.askHelp",
                         "Allow it only if these words match the ones %@ shows in Settings > Devices. After that, its switch turns this machine's Control and Screen sharing on and off without asking here again."),
               mac)
    }
    static var grantorAllow: String { allow }
    static var grantorDismiss: String { decline(.signedInMachines) }
    static func grantorSubtitle(words: [String]) -> String {
        String(format: s("devices.join.grantor.subtitle", "Can turn Control on and off here · %@"), words.joined(separator: " "))
    }
    static var grantorRemove: String { s("devices.remove", "Remove") }
    static var grantorTrustFailed: String { s("devices.join.grantor.trustFailed", "Not allowed: this Mac could not confirm it was you. Try again.") }
    /// The confirm's reason for trusting another Mac's key (LocalAuthentication shows it after the app's name).
    public static var grantorTrustReason: String {
        s("devices.join.grantor.confirmReason", "let your other Mac turn this Mac's Control and Screen sharing on and off")
    }
}
