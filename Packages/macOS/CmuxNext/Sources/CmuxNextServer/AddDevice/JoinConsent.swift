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

    public init(screen: Bool = false, control: Bool = false, lastRefusal: JoinConsentSurface? = nil, consentRequired: Bool? = nil) {
        self.screen = screen
        self.control = control
        self.lastRefusal = lastRefusal
        self.consentRequired = consentRequired
    }

    /// The record in a result; nil without a `consent` object. Only the word `granted` is on.
    public static func parse(_ result: [String: Any]) -> JoinConsentRecord? {
        guard let consent = result["consent"] as? [String: Any] else { return nil }
        let refusal = (result["lastRefusal"] as? [String: Any])?["surface"] as? String
        return JoinConsentRecord(screen: consent["screen"] as? String == "granted", control: consent["control"] as? String == "granted",
                                 lastRefusal: refusal.flatMap(JoinConsentSurface.init(rawValue:)),
                                 consentRequired: result["consentRequired"] as? Bool)
    }

    public func allows(_ surface: JoinConsentSurface) -> Bool { surface == .screen ? screen : control }
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
    func close()
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

/// A team machine's screen or control request that acpmux refused with `consent_required`.
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

/// This Mac's join consent: the two switches of Settings > Devices, the one-time sheet on the first
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
        if shown, let surface = reading.consent?.lastRefusal, reading.consent?.allows(surface) == false {
            refused(JoinConsentRefusal(requester: JoinConsentStrings.teamMachine, surface: surface))
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
        if surface == .screen { record.screen = false } else { record.control = false }
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
    /// shows the sheet, once. Later ones, or any while the Labs switch is off, show nothing.
    public func refused(_ refusal: JoinConsentRefusal) {
        guard services.enabled(), ask == nil, !services.askShown() else { return }
        services.markAskShown()
        ask = refusal
        askError = nil
        present(true)
    }

    /// The sheet's Deny or Allow. Allow writes through the same person path as the switch; when it does
    /// not take, the sheet stays up with the reason. While a write is in flight both buttons are disabled
    /// and a press does nothing, so a Deny never closes the sheet over a grant still landing.
    @discardableResult
    public func answer(allow: Bool) async -> String? {
        guard let refusal = ask, !writing else { return nil }
        guard allow, services.enabled() else {
            dismissAsk()
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
        }
    }
    static func switchHelp(_ surface: JoinConsentSurface) -> String {
        switch surface {
        case .screen: s("devices.join.screenHelp", "Your team's machines can see this screen")
        case .control: s("devices.join.controlHelp", "Your team's machines can move the pointer and type here")
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
        }
    }
    static var offFailed: String { s("devices.join.offFailed", "It could not be turned off. Try again.") }
    static var unread: String {
        s("devices.join.unread", "This Mac could not read what it allows, so Mac Screen is refused until it can. The switches come back when it reads again.")
    }
    static var busy: String { s("devices.join.busy", "Still saving the last change. Try again in a moment.") }
    static var revokeAll: String { s("devices.join.revokeAll", "Turn Off Screen Sharing and Control") }
    static var unsupported: String { s("devices.join.unsupported", "Still off: this Mac's cmux needs an update before you can allow this") }
    /// Who asked, when acpmux recorded only the refusal.
    static var teamMachine: String { s("devices.join.ask.teamMachine", "A machine on your team") }

    // The one-time sheet.
    static func askTitle(_ refusal: JoinConsentRefusal) -> String {
        switch refusal.surface {
        case .screen: String(format: s("devices.join.ask.screen", "%@ asked to see this screen."), refusal.requester)
        case .control: String(format: s("devices.join.ask.control", "%@ asked to control this Mac."), refusal.requester)
        }
    }
    static func askQuestion(_ surface: JoinConsentSurface) -> String {
        switch surface {
        case .screen: s("devices.join.ask.screenQuestion", "Allow screen sharing from your team's machines?")
        case .control: s("devices.join.ask.controlQuestion", "Allow control from your team's machines?")
        }
    }
    static var askNote: String { s("devices.join.ask.note", "You can change this later in Settings > Devices.") }
    static var deny: String { s("devices.join.ask.deny", "Deny") }
    static var allow: String { s("devices.join.ask.allow", "Allow") }
}
