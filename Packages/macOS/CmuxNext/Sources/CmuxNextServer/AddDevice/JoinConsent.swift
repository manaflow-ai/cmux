public import Foundation
public import Observation

/// What a joined machine's team may do on this Mac only after the person allows it here (the one-line
/// join's consent gate, contract §5). The join itself grants mesh membership alone; acpmux blocks
/// both surfaces until a consent record exists.
public nonisolated enum JoinConsentSurface: String, CaseIterable, Equatable, Sendable {
    /// Other team machines see this screen.
    case screen
    /// Other team machines move the pointer and type here.
    case control
}

/// `acpmux host join --status --json`: the parts This Mac shows. Consent reads either a bool or
/// `"granted"`/`"none"` (both shapes were proposed for the status line).
public nonisolated struct JoinStatus: Equatable, Sendable, Decodable {
    public var credentialPresent: Bool
    public var machineId: String?
    public var teamId: String?
    /// The team's name when the status carries one; else the page shows ``teamId``.
    public var teamName: String?
    /// The machine's name in the team; else the page shows ``machineId``.
    public var name: String?
    public var revoked: Bool
    public var screen: Bool
    public var control: Bool

    public init(credentialPresent: Bool, machineId: String? = nil, teamId: String? = nil, teamName: String? = nil,
                name: String? = nil, revoked: Bool = false, screen: Bool = false, control: Bool = false) {
        self.credentialPresent = credentialPresent
        self.machineId = machineId
        self.teamId = teamId
        self.teamName = teamName
        self.name = name
        self.revoked = revoked
        self.screen = screen
        self.control = control
    }

    private enum Keys: String, CodingKey { case credentialPresent, machineId, teamId, teamName, name, revoked, consent }
    private enum ConsentKeys: String, CodingKey { case screen, control }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        credentialPresent = try c.decodeIfPresent(Bool.self, forKey: .credentialPresent) ?? false
        machineId = try c.decodeIfPresent(String.self, forKey: .machineId)
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId)
        teamName = try c.decodeIfPresent(String.self, forKey: .teamName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
        let consent = try? c.nestedContainer(keyedBy: ConsentKeys.self, forKey: .consent)
        screen = Self.granted(consent, .screen)
        control = Self.granted(consent, .control)
    }

    /// A bool, or the word `granted`; anything else (absent, `none`, malformed) is off.
    private static func granted(_ c: KeyedDecodingContainer<ConsentKeys>?, _ key: ConsentKeys) -> Bool {
        guard let c else { return false }
        if let on = try? c.decode(Bool.self, forKey: key) { return on }
        return (try? c.decode(String.self, forKey: key)) == "granted"
    }

    public static func parse(_ data: Data) -> JoinStatus? { try? JSONDecoder().decode(JoinStatus.self, from: data) }

    public func allows(_ surface: JoinConsentSurface) -> Bool { surface == .screen ? screen : control }
}

/// One connection to this Mac's acpmux for consent writes (the app's ``AcpmuxPersonLine``). acpmux
/// takes an on only from a connection proven as the person, as `_acpmux/pair_set`'s Full access does.
@MainActor
public protocol JoinConsentLine: AnyObject {
    var isPerson: Bool { get }
    /// Writes the consent record; true when acpmux took it.
    func set(_ surface: JoinConsentSurface, on: Bool) async -> Bool
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

/// This Mac's join consent: the two switches of Settings > Devices and the one-time sheet on the first
/// refused request. Turning a switch on needs a line acpmux proved as the person (``JoinConsentLine/isPerson``);
/// off always works. It reads the status only when asked (Settings opening, after a write).
@MainActor @Observable
public final class JoinConsentModel {
    public private(set) var status: JoinStatus?
    /// Why the last write failed; nil after a success.
    public private(set) var lastError: String?
    /// The refused request the one-time sheet shows; nil while it is hidden.
    public private(set) var ask: JoinConsentRefusal?
    /// Why the sheet's Allow did not take; the sheet stays up showing it.
    public private(set) var askError: String?
    /// Shows and hides the sheet; the app sets the panel, tests record it.
    @ObservationIgnored public var present: @MainActor (Bool) -> Void = { _ in }
    @ObservationIgnored private let services: JoinConsentServices

    public init(services: JoinConsentServices) {
        self.services = services
    }

    /// The switches show: the Labs switch is on and this Mac holds a join credential that is not revoked.
    public var shown: Bool { services.enabled() && status?.credentialPresent == true && status?.revoked != true }

    public func refresh() async {
        status = services.enabled() ? await services.status() : nil
        // The Labs switch went off (or the join went away): an open sheet can no longer allow.
        if !shown, ask != nil { dismissAsk() }
    }

    /// Turns `surface` on or off on this Mac. Returns the error to show, nil when set.
    @discardableResult
    public func set(_ surface: JoinConsentSurface, on: Bool) async -> String? {
        // An on only for a joined, unrevoked Mac with the Labs switch on, read fresh; off always goes through.
        if on {
            await refresh()
            guard shown else {
                lastError = JoinConsentStrings.onFailed
                return lastError
            }
        }
        guard let line = await services.openLine() else {
            lastError = on ? JoinConsentStrings.onFailed : JoinConsentStrings.offFailed
            return lastError
        }
        defer { line.close() }
        // SECURITY: only the person at this Mac turns a surface on; a revoke narrows, so any line may.
        if on, !line.isPerson {
            lastError = JoinConsentStrings.onFailed
            return lastError
        }
        let ok = await line.set(surface, on: on)
        lastError = ok ? nil : on ? JoinConsentStrings.onFailed : JoinConsentStrings.offFailed
        await refresh()
        return lastError
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
    /// not take, the sheet stays up with the reason (Deny still closes it).
    @discardableResult
    public func answer(allow: Bool) async -> String? {
        guard let refusal = ask else { return nil }
        guard allow else {
            dismissAsk()
            return nil
        }
        guard services.enabled() else {
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
            error: lastError,
            switches: JoinConsentSurface.allCases.map {
                JoinConsentPage.Switch(surface: $0.rawValue, title: JoinConsentStrings.title($0), help: JoinConsentStrings.switchHelp($0),
                                       on: status.allows($0))
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
    var switches: [Switch]
}

/// Text of the join consent (Resources/AddDevice.xcstrings).
public nonisolated enum JoinConsentStrings {
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
