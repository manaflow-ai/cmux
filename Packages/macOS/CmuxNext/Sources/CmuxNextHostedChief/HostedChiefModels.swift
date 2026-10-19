import Foundation

/// One of the user's cloud chiefs (`chief.list`, `HomeChief`), the fields the
/// app reads. `brainPlace` names the paired server whose install answers as
/// this chief (G8, brains/DESIGN-cmux-lawrence.md); nil means no machine is
/// placed (an older backend leaves the key out, which reads the same).
public nonisolated struct CloudChief: Sendable, Equatable {
    public nonisolated struct BrainPlace: Sendable, Equatable {
        public var host: String
        public var install: String

        public init(host: String, install: String) {
            self.host = host
            self.install = install
        }
    }

    public var id: String
    public var displayName: String
    public var isDefault: Bool
    public var mainConversation: String?
    public var rev: Int
    public var brainPlace: BrainPlace?

    /// One `HomeChief` value; nil when a required field is missing.
    public static func parse(_ value: Any?) -> CloudChief? {
        guard let value = value as? [String: Any], let id = value["id"] as? String,
              let rev = (value["rev"] as? NSNumber)?.intValue else { return nil }
        var place: BrainPlace?
        if let raw = value["brain_place"] as? [String: Any], let host = raw["host"] as? String, let install = raw["install"] as? String {
            place = BrainPlace(host: host, install: install)
        }
        return CloudChief(id: id, displayName: value["display_name"] as? String ?? "", isDefault: value["is_default"] as? Bool ?? false,
                          mainConversation: value["main_conversation"] as? String, rev: rev, brainPlace: place)
    }
}

/// The user's two cloud Chiefs in Home (Lawrence 2026-10-19): the Hosted
/// Chief (no `brain_place`; the Cloud brain answers, so Home works while the
/// user's Macs are off) is the default, and a Chief placed on a paired server
/// stays as "Chief (Mac mini)", one tap away.
public nonisolated struct HomeCloudChiefs: Sendable, Equatable {
    public var hosted: CloudChief?
    public var placed: CloudChief?

    public init(hosted: CloudChief? = nil, placed: CloudChief? = nil) {
        self.hosted = hosted
        self.placed = placed
    }

    /// Which of the two the Chief tab shows: the placed one only when the
    /// user picked it and it exists; else the hosted one, else the placed one.
    public func shown(choice: HomeChiefChoice) -> CloudChief? {
        if choice == .placed, let placed { return placed }
        return hosted ?? placed
    }

    /// The cloud Chief whose main conversation is `conversation`.
    public func chief(for conversation: String) -> CloudChief? {
        [hosted, placed].compactMap { $0 }.first { $0.mainConversation == conversation }
    }

    /// Both exist: the Chief tab offers the switch.
    public var canSwitch: Bool { hosted?.mainConversation != nil && placed?.mainConversation != nil }

    /// The active chief with no machine placed: the default one, else the first.
    public static func hosted(in chiefs: [CloudChief]) -> CloudChief? {
        let hosted = chiefs.filter { $0.brainPlace == nil && $0.mainConversation != nil }
        return hosted.first(where: \.isDefault) ?? hosted.first
    }

}

/// The Chief the user picked for the Chief tab, kept on this Mac (client view state).
public nonisolated enum HomeChiefChoice: String, Sendable {
    case hosted
    case placed

    private static let key = "home.chief.choice"

    @MainActor public static func load(_ defaults: UserDefaults = .standard) -> HomeChiefChoice {
        defaults.string(forKey: key).flatMap(HomeChiefChoice.init(rawValue:)) ?? .hosted
    }

    @MainActor public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.key)
    }
}

/// The Hosted Chief's user-facing text (HostedChief.xcstrings).
extension HomeCloudChiefs {
    /// The name of the placed Chief once the Hosted Chief is the default.
    public static var placedName: String {
        String(localized: "home.chief.placedName", defaultValue: "Chief (Mac mini)", table: "HostedChief", bundle: .module)
    }

    public static var switchHelp: String {
        String(localized: "home.chief.switch.help", defaultValue: "Choose which Chief answers here", table: "HostedChief", bundle: .module)
    }

    public static var brainFailed: String {
        String(localized: "home.chief.hostedBrainFailed",
               defaultValue: "Your cloud Chief could not be turned on, so it does not answer yet. cmux tries again at the next launch.",
               table: "HostedChief", bundle: .module)
    }

    public static var brainOff: String {
        String(localized: "home.chief.hostedBrainOff", defaultValue: "Your cloud Chief is turned off, so it does not answer messages.",
               table: "HostedChief", bundle: .module)
    }

    public static var copyFailed: String {
        String(localized: "home.chief.hostedCopyFailed",
               defaultValue: "Your Chief's history could not be copied to the cloud yet. cmux tries again at the next launch.",
               table: "HostedChief", bundle: .module)
    }
}
