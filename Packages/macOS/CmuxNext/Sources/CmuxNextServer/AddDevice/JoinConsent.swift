public import Foundation
public import Observation
public import CmuxNextPages
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

    public init(screen: Bool = false, control: Bool = false, lastRefusal: JoinConsentSurface? = nil, consentRequired: Bool? = nil,
                signedInMachines: Bool = false, lastRefusalFrom: String? = nil, signedInMachinesAskOpen: Bool = false,
                lastRefusalAt: Double? = nil) {
        self.screen = screen
        self.control = control
        self.lastRefusal = lastRefusal
        self.consentRequired = consentRequired
        self.signedInMachines = signedInMachines
        self.lastRefusalFrom = lastRefusalFrom
        self.signedInMachinesAskOpen = signedInMachinesAskOpen
        self.lastRefusalAt = lastRefusalAt
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
        return JoinConsentRecord(screen: consent["screen"] as? String == "granted", control: consent["control"] as? String == "granted",
                                 lastRefusal: surface, consentRequired: result["consentRequired"] as? Bool,
                                 signedInMachines: consent["signedInMachines"] as? String == "granted", lastRefusalFrom: from,
                                 signedInMachinesAskOpen: open, lastRefusalAt: surface == .signedInMachines ? askedAt : nil)
    }

    public func allows(_ surface: JoinConsentSurface) -> Bool {
        switch surface {
        case .screen: screen
        case .control: control
        case .signedInMachines: signedInMachines
        }
    }
}

/// Why Settings > Devices has no consent record it may change: each way the page ends up without
/// one, with its own line on the page (``JoinConsentModel/pageData()``) and in the app's log.
public nonisolated enum JoinConsentUnread: Equatable, Sendable, CustomStringConvertible {
    /// No acpmux runs for this app: no socket at `path`, or the app has none (a mock agent host).
    case notRunning(path: String?)
    /// The app refused the acpmux on its socket, or could not connect (the refusal's words).
    case refused(String)
    /// The acpmux connected but never answered `initialize` before the deadline, or closed.
    case noAnswer
    /// The acpmux on the socket is another install's that predates the person challenge (`path`).
    case olderDaemon(path: String)
    /// The acpmux has no `machine-consent-v1`.
    case unsupported
    /// `_acpmux/machine_consent_get` failed (acpmux's words, when it gave any).
    case readFailed(String?)
    /// The record was read, but acpmux did not take this app's person proof, so nothing can change:
    /// `foreignPath` is the other install's acpmux that answers on this app's socket (the app never
    /// proves there), nil for this app's own one without its key (`why`).
    case notProven(foreignPath: String?, why: String)

    public var description: String {
        switch self {
        case .notRunning(let path): "no acpmux runs at \(path ?? "(no acpmux for this app)")"
        case .refused(let why): "the acpmux on the socket was refused: \(why)"
        case .noAnswer: "acpmux did not answer initialize"
        case .olderDaemon(let path): "the acpmux on the socket is \(path), which predates the person challenge"
        case .unsupported: "acpmux has no machine-consent-v1"
        case .readFailed(let why): "machine_consent_get failed: \(why ?? "no record in its answer, or the line closed")"
        case .notProven(let path?, let why): "read from \(path), not the acpmux this app runs, so it is not proven the person's: \(why)"
        case .notProven(nil, let why): "acpmux did not take this app's person proof: \(why)"
        }
    }

    /// The page's line for it.
    var pageText: String {
        switch self {
        case .notRunning: JoinConsentStrings.notRunning
        case .refused: JoinConsentStrings.refusedDaemon
        case .noAnswer: JoinConsentStrings.noAnswer
        case .olderDaemon: JoinConsentStrings.olderDaemon
        case .unsupported: JoinConsentStrings.unsupported
        case .readFailed: JoinConsentStrings.unread
        case .notProven(let path?, _): JoinConsentStrings.otherDaemon(path)
        case .notProven(nil, _): JoinConsentStrings.notProven
        }
    }
}

/// What ``JoinConsentServices/open`` got: a line, or why there is none.
public enum JoinConsentOpen {
    case line(any JoinConsentLine)
    case failed(JoinConsentUnread)
}

/// One connection to this Mac's acpmux for the consent record (the app's ``AcpmuxPersonLine``). acpmux
/// changes it only for a connection proven as the person, as `_acpmux/pair_set`'s Full access does.
@MainActor
public protocol JoinConsentLine: AnyObject {
    var isPerson: Bool { get }
    /// Why ``isPerson`` is false (a ``JoinConsentUnread/notProven(foreignPath:why:)``); nil when it is not.
    var notProven: JoinConsentUnread? { get }
    /// acpmux's words for the last failed ``read()``, when it gave any.
    var readError: String? { get }
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

extension JoinConsentLine {
    public var notProven: JoinConsentUnread? { isPerson ? nil : .notProven(foreignPath: nil, why: "not the person's") }
    public var readError: String? { nil }
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
    /// ``openLine`` that says why it got no line; what the model reads with. Without one given, a nil
    /// ``openLine`` is ``JoinConsentUnread/noAnswer``.
    public var open: @MainActor () async -> JoinConsentOpen
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

    public init(status: @escaping @MainActor () async -> JoinStatus?, openLine: (@MainActor () async -> (any JoinConsentLine)?)? = nil,
                enabled: @escaping @MainActor () -> Bool, settingsEpoch: @escaping @MainActor () -> Int = { 0 },
                confirmOwner: @escaping @MainActor (JoinConsentSurface) async -> JoinConsentConfirm = JoinConsentServices.cannotConfirm,
                askShown: @escaping @MainActor () -> Bool, markAskShown: @escaping @MainActor () -> Void,
                open: (@MainActor () async -> JoinConsentOpen)? = nil) {
        self.status = status
        // One of the two, the other made from it: a nil line without `open` is ``JoinConsentUnread/noAnswer``.
        let open: @MainActor () async -> JoinConsentOpen = open ?? { await openLine?().map(JoinConsentOpen.line) ?? .failed(.noAnswer) }
        self.open = open
        self.openLine = openLine ?? {
            if case .line(let line) = await open() { return line }
            return nil
        }
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
    /// Why the last applied read left the page without a record it may change; nil when it has one.
    public private(set) var unread: JoinConsentUnread?
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
        var unread: JoinConsentUnread?
        /// SECURITY: the record Mac Screen may serve on: nil for one another install's acpmux answered (any
        /// same-user process may bind the socket and say granted), which the page only shows.
        var gating: JoinConsentRecord? {
            if case .notProven(foreignPath: _?, _)? = unread { return nil }
            return consent
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "join-consent")

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
        unread = nil
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
            switch await services.open() {
            case .failed(let why):
                reading.unread = why
            case .line(let line):
                reading.supported = line.supportsConsent
                if line.supportsConsent {
                    reading.consent = await line.read()
                    reading.unread = reading.consent == nil ? .readFailed(line.readError) : line.notProven
                } else {
                    reading.unread = .unsupported
                }
                line.close()
            }
            // Every way the page is left without a record it may change says why, here and on the page.
            if let why = reading.unread { Self.logger.error("join consent: \(why.description, privacy: .public)") }
        }
        guard !duringWrite, mine == generation, kind == .afterWrite || !writing else { return (reading, false) }
        apply(reading)
        return (reading, true)
    }

    private func apply(_ reading: Reading) {
        status = reading.status
        consent = reading.consent
        verified = reading.gating
        consentSupported = reading.supported
        unread = reading.unread
        changed()
        // The Labs switch went off, or the join went away or was revoked (said so, not merely unread): an
        // open sheet can no longer allow.
        let gone = !enabled || reading.status?.credentialPresent == false || reading.status?.revoked == true
        if gone, ask != nil { dismissAsk() }
        // acpmux refused a team machine for a surface still off: the first such refusal shows the sheet.
        // One of the person's other Macs asking for a workspace shows it while that ask is unanswered
        // (acpmux keeps the answer), naming the Mac when acpmux recorded it, unless the sheet already
        // showed that ask here.
        // Not for another install's record (gating nil): its Allow can never take there.
        if shown, let record = reading.gating, let surface = record.lastRefusal, !record.allows(surface) {
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
        guard !writing else {
            Self.logger.error("join consent: \(surface.rawValue, privacy: .public) not written: another write is in flight")
            return JoinConsentStrings.busy
        }
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
        // Every way it is not written says why on the page (or the sheet) and in the log: never a silent no.
        let refuse = { (text: String, why: String) -> (String?, JoinConsentRecord?) in
            Self.logger.error("join consent: \(surface.rawValue, privacy: .public) \(on ? "on" : "off", privacy: .public) not written: \(why, privacy: .public)")
            return (text, nil)
        }
        if on {
            // An on only for a joined, unrevoked Mac with the Labs switch on, as this read finds it (acpmux
            // checks the person itself; this keeps a grant off a Mac that shows no switches).
            let (reading, _) = await read(.writeCheck)
            guard enabled else { return refuse(JoinConsentStrings.changedMeanwhile, "the Labs switch is off") }
            // An unread join status (the CLI failed) is not "not joined": it says only that this Mac could not confirm.
            guard let joinStatus = reading.status else { return refuse(failed, "this Mac's join status could not be read") }
            guard joinStatus.credentialPresent, !joinStatus.revoked else {
                return refuse(JoinConsentStrings.notJoined, joinStatus.revoked ? "this Mac's join was revoked" : "this Mac is not joined")
            }
            // SECURITY: the device owner confirms every grant (Touch ID or the login password), whatever the
            // input that asked for it: an event's source fields can be forged by a process allowed to post
            // events, and a posted event can't pass this. The person-input checks before it only refuse
            // early; they never grant on their own. A Labs change or settings load meanwhile still drops
            // the grant (checked again below).
            switch await services.confirmOwner(surface) {
            case .confirmed: break
            case .cancelled: return refuse(JoinConsentStrings.confirmCancelled, "the device owner's confirm was cancelled or failed")
            case .unavailable: return refuse(JoinConsentStrings.confirmUnavailable, "this Mac can't ask for Touch ID or the login password")
            }
        }
        let line: any JoinConsentLine
        switch await services.open() {
        case .line(let opened): line = opened
        case .failed(let why): return refuse(why.pageText, "no line to acpmux: \(why.description)")
        }
        defer { line.close() }
        // SECURITY: only the person at this Mac turns a surface on (acpmux also takes a revoke only from
        // the person's connection; the page asks no gesture for one, since it narrows).
        if on, !line.isPerson {
            let why = line.notProven ?? .notProven(foreignPath: nil, why: "not the person's")
            return refuse(why.pageText, why.description)
        }
        guard line.supportsConsent else { return refuse(on ? JoinConsentStrings.unsupported : failed, JoinConsentUnread.unsupported.description) }
        // The Labs switch may have turned off (and on again) while the line opened: a grant is sent only
        // at its own generation, with the switch on and no settings load since it started. The line checks
        // the ticket once more as it writes, since either can change after this check.
        if on, !enabled || generation != mine || services.settingsEpoch() != epoch {
            return refuse(JoinConsentStrings.changedMeanwhile, "the Labs switch or the settings changed while it was asked")
        }
        guard let written = await line.set(surface, granted: on, ticket: on ? ticket : nil) else {
            let said = line.readError
            return refuse(said.map(JoinConsentStrings.acpmuxRefused) ?? failed, "machine_consent_set failed: \(said ?? "no answer, or the settings changed as it was sent")")
        }
        return (nil, written)
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
        guard reading.supported == true, let consent = reading.gating else { return false }
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
        // Not for another install's record (gating nil): its Allow can never take, and the Mac's one ask would be spent.
        if reading.supported == false || reading.gating != nil, Self.joined(reading) {
            refused(JoinConsentRefusal(requester: requester, surface: reading.gating?.screen == true ? .control : .screen))
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

    /// The sheet's Allow refused an input that is not the person's own click (``JoinConsentAskPanel``):
    /// the gate stays shut, and the sheet says so instead of doing nothing. `why` goes to the log.
    public func allowRefused(why: String) {
        guard ask != nil else { return }
        Self.logger.error("join consent: the sheet's Allow refused \(why, privacy: .public)")
        askError = JoinConsentStrings.personOnly
        present(true)
    }

    /// SECURITY: the Settings page turns a switch on only from the person's own click or key in that page,
    /// spent once, and only one the HID system made (`backs`): a posted click (the cmux-cua helper's, or a
    /// remote driver's) never grants more. Off needs none, since it narrows. A refusal is logged with its
    /// reason and answers "Only a click by the person at this Mac can allow this."
    public static func requirePersonGesture(_ context: PageCallContext, page: String, backs: (@MainActor (TimeInterval) -> Bool)?,
                                            claim: @MainActor (TimeInterval) -> Bool) throws {
        let refuse = { (why: String) -> PageError in
            logger.error("join consent: the Settings page's on refused: \(why, privacy: .public)")
            return PageError(code: PageNativeOp.userOnlyCode, message: JoinConsentStrings.personOnly)
        }
        guard context.page == page else { throw refuse("asked from another page (\(context.page))") }
        guard context.userGesture, let event = context.gestureEvent else { throw refuse("no click or key of the person's came with it") }
        guard backs?(event) == true else { throw refuse("the click is not the HID system's own input (posted by a process or a remote driver)") }
        guard claim(event) else { throw refuse("that click already turned a switch on") }
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
        // Read but not the person's: the switches show what acpmux holds, and none can change, off included
        // (acpmux takes a revoke only from the person too), so no Turn All Off either.
        var proven = true
        if case .notProven? = unread { proven = false }
        let known = consentSupported == true && consent != nil && proven
        let why = consentSupported == false ? JoinConsentUnread.unsupported : unread ?? .readFailed(nil)
        let page = JoinConsentPage(
            title: JoinConsentStrings.section, joined: JoinConsentStrings.joined(team: team, name: name), help: JoinConsentStrings.help,
            error: lastError ?? (consentSupported == false || consent == nil || !proven ? why.pageText : nil),
            busy: writing,
            known: known,
            revokeAll: known || !proven ? nil : JoinConsentStrings.revokeAll,
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
    static var notRunning: String {
        s("devices.join.notRunning", "cmux's background service isn't running, so Mac Screen is refused.")
    }
    static var refusedDaemon: String {
        s("devices.join.refusedDaemon", "cmux doesn't trust the program answering for its background service, so Mac Screen is refused.")
    }
    static var noAnswer: String {
        s("devices.join.noAnswer", "cmux's background service did not answer, so cmux can't read what this Mac allows. Mac Screen is refused until it can.")
    }
    static var olderDaemon: String {
        s("devices.join.olderDaemon", "An older copy of cmux's background service is running, so cmux can't read what this Mac allows. Quit it so cmux runs its own.")
    }
    /// Another install's acpmux (`path`) answers on cmux's socket: it shows what it holds, and cmux can't prove it's you there.
    static func otherDaemon(_ path: String) -> String {
        String(format: s("devices.join.otherDaemon", "Another copy of cmux's background service is running (%@), so these can't change. Quit it so cmux runs its own."), path)
    }
    static var notProven: String {
        s("devices.join.notProven", "cmux could not prove it's you to its background service, so these can't change. Quit and reopen cmux to try again.")
    }
    /// The Settings switch's or the sheet's Allow refused an input that is not the person's own click.
    public static var personOnly: String { s("devices.join.personOnly", "Only a click by the person at this Mac can allow this.") }
    static var notJoined: String { s("devices.join.notJoined", "Still off: this Mac is not joined to a team, or its join was revoked.") }
    static var changedMeanwhile: String {
        s("devices.join.changedMeanwhile", "Still off: the Labs switch or the settings changed while it was being turned on. Try again.")
    }
    static var confirmCancelled: String {
        s("devices.join.confirmCancelled", "Still off: Touch ID or your login password was cancelled, so this Mac could not confirm it was you.")
    }
    static func acpmuxRefused(_ said: String) -> String {
        String(format: s("devices.join.acpmuxRefused", "cmux's background service did not take it: %@"), said)
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
}

#if DEBUG
/// `debug.join_consent`'s line (the app's DebugJoinConsent): one acpmux proved as the person, over a fixture record.
@MainActor
public final class JoinConsentFixtureLine: JoinConsentLine {
    public var record = JoinConsentRecord()
    public var isPerson: Bool { true }
    public var supportsConsent: Bool { true }
    public init() {}
    public func read() async -> JoinConsentRecord? { record }
    public func set(_ surface: JoinConsentSurface, granted: Bool, ticket: JoinConsentGrantTicket?) async -> JoinConsentRecord? {
        guard ticket?.write({}) ?? true else { return nil }
        if surface == .screen { record.screen = granted } else { record.control = granted }
        return record
    }
    public func close() {}
}
#endif
