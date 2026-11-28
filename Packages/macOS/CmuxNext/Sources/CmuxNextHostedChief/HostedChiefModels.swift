public import CmuxChiefList
import CmuxNextHomeEngine
public import Foundation

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

    /// - Parameters:
    ///   - id: The chief's id.
    ///   - displayName: Its name.
    ///   - isDefault: It is the user's default chief.
    ///   - mainConversation: Its main conversation, when it has one.
    ///   - rev: The record's revision.
    ///   - brainPlace: The paired server that answers as it; nil runs it in the cloud.
    public init(id: String, displayName: String, isDefault: Bool, mainConversation: String?, rev: Int, brainPlace: BrainPlace? = nil) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
        self.mainConversation = mainConversation
        self.rev = rev
        self.brainPlace = brainPlace
    }

    /// One `HomeChief` value; nil when a required field is missing (Rust `chief_home.cloud_parse`).
    public static func parse(_ value: Any?) -> CloudChief? {
        struct Reply: Decodable { let chief: Wire? }
        return ((try? ChiefHomeRules().call("cloud_parse", value: value)) as Reply?)?.chief?.chief
    }

    /// The rules' form of a cloud chief (Rust `CloudChief`, camelCase).
    struct Wire: Codable {
        struct Place: Codable { let host: String; let install: String }
        let id: String
        let displayName: String
        let isDefault: Bool
        let mainConversation: String?
        let rev: Int
        let brainPlace: Place?

        init(_ chief: CloudChief) {
            id = chief.id
            displayName = chief.displayName
            isDefault = chief.isDefault
            mainConversation = chief.mainConversation
            rev = chief.rev
            brainPlace = chief.brainPlace.map { Place(host: $0.host, install: $0.install) }
        }

        var chief: CloudChief {
            CloudChief(id: id, displayName: displayName, isDefault: isDefault, mainConversation: mainConversation, rev: rev,
                       brainPlace: brainPlace.map { BrainPlace(host: $0.host, install: $0.install) })
        }
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

    /// What the rules say of these two (Rust `chief_home.cloud_chiefs`); nil when they cannot run.
    private struct Rules: Decodable {
        let shown: CloudChief.Wire?
        let chiefFor: CloudChief.Wire?
        let canSwitch: Bool
        let otherHost: String?
    }

    private func rules(choice: HomeChiefChoice = .hosted, conversation: String? = nil) -> Rules? {
        struct Request: Encodable {
            let hosted: CloudChief.Wire?
            let placed: CloudChief.Wire?
            let choice: String
            let conversation: String?
        }
        let request = Request(hosted: hosted.map(CloudChief.Wire.init), placed: placed.map(CloudChief.Wire.init),
                              choice: choice.rawValue, conversation: conversation)
        return try? ChiefHomeRules().call("cloud_chiefs", request)
    }

    /// Which of the two the Chief tab shows: the placed one only when the
    /// user picked it and it exists; else the hosted one, else the placed one.
    public func shown(choice: HomeChiefChoice) -> CloudChief? { rules(choice: choice)?.shown?.chief }

    /// The Chief Slack talks to (RFD 0123: cmux-api routes Slack to the default Chief): the default one, else the hosted one.
    public var slackChief: CloudChief? {
        [hosted, placed].compactMap { $0 }.first { $0.isDefault } ?? hosted
    }

    /// The cloud Chief whose main conversation is `conversation`.
    public func chief(for conversation: String) -> CloudChief? { rules(conversation: conversation)?.chiefFor?.chief }

    /// Both exist: the Chief tab offers the switch.
    public var canSwitch: Bool { rules()?.canSwitch ?? false }

    /// The other host the Chief's card offers on `conversation`: the placed
    /// Chief on the Hosted Chief's card and back; nil unless both exist and
    /// `conversation` is one of them.
    public func otherHost(of conversation: String) -> HomeChiefChoice? {
        rules(conversation: conversation)?.otherHost.flatMap(HomeChiefChoice.init(rawValue:))
    }

    /// The active chief with no machine placed: the default one, else the first.
    public static func hosted(in chiefs: [CloudChief]) -> CloudChief? {
        ChiefList.hosted(in: chiefs)  // the one rule, the iPhone's too
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
        String(localized: "home.chief.placedName", defaultValue: "Chief (Mac mini)", table: "HostedChief", bundle: .localizedModule)
    }

    public static var brainFailed: String {
        String(localized: "home.chief.hostedBrainFailed",
               defaultValue: "Your cloud Chief could not be turned on, so it does not answer yet. cmux tries again at the next launch.",
               table: "HostedChief", bundle: .localizedModule)
    }

    public static var brainOff: String {
        String(localized: "home.chief.hostedBrainOff", defaultValue: "Your cloud Chief is turned off, so it does not answer messages.",
               table: "HostedChief", bundle: .localizedModule)
    }

    public static var copyFailed: String {
        String(localized: "home.chief.hostedCopyFailed",
               defaultValue: "Your Chief's history could not be copied to the cloud yet. cmux tries again at the next launch.",
               table: "HostedChief", bundle: .localizedModule)
    }
}

/// The JSON of the Rust rules (`cloud::reach::CloudChief`, `cloud::chiefs::Chiefs`): camelCase,
/// nil fields left out.
nonisolated extension CloudChief.BrainPlace: Codable {}
nonisolated extension CloudChief: Codable {}
nonisolated extension HomeCloudChiefs: Codable {}
nonisolated extension HomeChiefChoice: Codable {}

/// A cloud Chief as the shared Chief list rule reads it (CmuxChiefList).
nonisolated extension CloudChief: ChiefListCloudChief {
    public var isPlaced: Bool { brainPlace != nil }
}
