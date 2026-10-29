public import Foundation
public import Observation

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
    /// `_acpmux/machine_consent_set`; true when acpmux took it.
    func set(_ surface: JoinConsentSurface, granted: Bool) async -> Bool
    func close()
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

/// What the consent gate asks of the app, so tests run it with fakes. Every call runs on the main actor.
public struct JoinConsentServices {
    /// `acpmux host join --status --json`; nil when this Mac is not joined or the run failed.
    public var status: @MainActor () async -> JoinStatus?
    /// A person-proof line to this Mac's acpmux; nil when no acpmux answers.
    public var openLine: @MainActor () async -> (any JoinConsentLine)?
    /// `labs.machineJoin`.
    public var enabled: @MainActor () -> Bool
    /// The one-time sheet already showed on this Mac (kept across launches).
    public var askShown: @MainActor () -> Bool
    public var markAskShown: @MainActor () -> Void

    public init(status: @escaping @MainActor () async -> JoinStatus?, openLine: @escaping @MainActor () async -> (any JoinConsentLine)?,
                enabled: @escaping @MainActor () -> Bool, askShown: @escaping @MainActor () -> Bool,
                markAskShown: @escaping @MainActor () -> Void) {
        self.status = status
        self.openLine = openLine
        self.enabled = enabled
        self.askShown = askShown
        self.markAskShown = markAskShown
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
    /// acpmux's record; nil before the first read, when the read failed, or when acpmux has no record.
    public private(set) var consent: JoinConsentRecord?
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
    @ObservationIgnored private let services: JoinConsentServices
    /// The newest request's generation; only its result is applied.
    @ObservationIgnored private(set) var generation = 0

    public init(services: JoinConsentServices) {
        self.services = services
    }

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

    /// Takes the next generation and reads. The result is applied, and `current` is true, only while no
    /// newer request started meanwhile and no write is in flight (a write's own read after it lands
    /// excepted, `afterWrite`); the reading comes back either way.
    private func read(afterWrite: Bool = false) async -> (reading: Reading, current: Bool) {
        generation += 1
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
        guard mine == generation, afterWrite || !writing else { return (reading, false) }
        apply(reading)
        return (reading, true)
    }

    private func apply(_ reading: Reading) {
        status = reading.status
        consent = reading.consent
        consentSupported = reading.supported
        changed()
        // The Labs switch went off (or the join went away): an open sheet can no longer allow.
        if !shown, ask != nil { dismissAsk() }
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
        if !on, var record = consent {
            // SECURITY: a revoke narrows at once, before acpmux answers: a running session stops now, and
            // no read that started before it (which may say granted) is applied.
            if surface == .screen { record.screen = false } else { record.control = false }
            consent = record
            changed()
        }
        lastError = await write(surface, on: on)
        // What acpmux holds now, whichever way the write went; reads made meanwhile are never applied.
        _ = await read(afterWrite: true)
        return lastError
    }

    /// The write itself; the error to show, nil when acpmux took it.
    private func write(_ surface: JoinConsentSurface, on: Bool) async -> String? {
        let failed = on ? JoinConsentStrings.onFailed : JoinConsentStrings.offFailed
        if on {
            // An on only for a joined, unrevoked Mac with the Labs switch on, as this read finds it (acpmux
            // checks the person itself; this keeps a grant off a Mac that shows no switches).
            let (reading, _) = await read()
            guard services.enabled(), reading.status?.credentialPresent == true, reading.status?.revoked != true else { return failed }
        }
        guard let line = await services.openLine() else { return failed }
        defer { line.close() }
        // SECURITY: only the person at this Mac turns a surface on (acpmux also takes a revoke only from
        // the person's connection; the page asks no gesture for one, since it narrows).
        if on, !line.isPerson { return failed }
        guard line.supportsConsent else { return on ? JoinConsentStrings.unsupported : failed }
        return await line.set(surface, granted: on) ? nil : failed
    }

    private func setWriting(_ on: Bool) {
        writing = on
        if ask != nil { redraw() }
    }

    /// What the applied read allows a running Mac Screen session (no read, nothing). With the Labs
    /// switch off, everything, as before. With it on: a Mac acpmux reports not joined
    /// (`consentRequired: false`) serves as before, which is acpmux's own rule; any other serves View
    /// Only with Screen sharing granted and Full Control with Control granted too.
    public func permitsMacScreen(control: Bool) -> Bool {
        guard services.enabled() else { return true }
        return Self.permits(Reading(status: status, consent: consent, supported: consentSupported), control: control)
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
    /// it answers, allows it, and no write is in flight. A refusal on a Mac read as joined shows the sheet.
    public func allowsMacScreen(control: Bool, requester: String) async -> Bool {
        guard services.enabled() else { return true }
        guard !writing else { return false }
        let (reading, current) = await read()
        guard current, !writing else { return false }
        if Self.permits(reading, control: control) { return true }
        if reading.supported != nil, Self.joined(reading) {
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
        dismissAsk()
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
            error: lastError ?? (consentSupported == false ? JoinConsentStrings.unsupported : nil), busy: writing,
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
    static var offFailed: String { s("devices.join.offFailed", "It could not be turned off. Try again.") }
    static var busy: String { s("devices.join.busy", "Still saving the last change. Try again in a moment.") }
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
