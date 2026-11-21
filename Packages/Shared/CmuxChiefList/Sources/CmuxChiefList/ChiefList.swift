/// Where a Chief's brain runs, as every Home's list and the Chief's card name it
/// (Lawrence 2026-10-19: "maybe some are living in cloud and mac minis idk this is
/// super confusing"): the Mac whose Home this is, the cloud, or one paired server.
public enum ChiefPlace: Hashable, Sendable, Codable {
    /// The Mac's own Chief owner (the default Chief before a cloud Chief, or a named local Chief).
    /// The Mac's list labels it "This Mac"; the iPhone labels it with that Mac's name.
    case thisMac
    /// The Hosted Chief: the Cloud brain answers, so it works while the user's Macs are off.
    case cloud
    /// A paired server's install answers; the value is the server's name (or its host id when unnamed).
    case server(String)
}

/// Which Chief is the default (#64, 2026-10-21): the Mac's Chief while its optchat-chief runs,
/// else the Hosted (cloud) Chief. Settings > Chief's Engine row (`home.chiefEngine`) can force either.
public enum ChiefDefault: String, Sendable, CaseIterable {
    /// The Mac's Chief while its optchat-chief runs, else the Hosted Chief.
    case auto
    /// Always the Mac's Chief.
    case local
    /// Always the cloud Chief (the Hosted Chief, or the server's when the user switched to it).
    case hosted

    /// The choice `home.chiefEngine` names; Auto for none or an unknown value.
    public init(setting: String?) {
        self = setting.flatMap(Self.init(rawValue:)) ?? .auto
    }

    /// The Mac's Chief is the default: forced, or Auto while the Mac's optchat-chief runs.
    public func prefersLocal(localRunning: Bool) -> Bool {
        switch self {
        case .auto: localRunning
        case .local: true
        case .hosted: false
        }
    }
}

/// The user's Chiefs as every Home lists them, on the Mac and on the iPhone alike (user
/// 2026-11-17: "make sure that they both display the same exact chief list using the same exact
/// mechanism"). Every Chief on every host is listed at once (Lawrence 2026-10-20: "local chiefs and
/// cloud chiefs and mac mini chiefs etc all at the same time"), one of them is Main (2026-10-19:
/// "idk which is main one"), and each is tagged with where it runs. No host's Chief is hidden.
///
/// Conversations are plain ids, so the Mac (`ConversationID`) and the iPhone (`String`) both pass theirs.
public struct ChiefList: Hashable, Sendable, Codable {
    /// One Chief conversation a Home knows, in that Home's list order.
    public struct Chief: Hashable, Sendable {
        /// Its conversation id.
        public var conversation: String
        /// The cloud owner lists it (a cloud Chief), not the Mac's own Chief owner.
        public var isCloud: Bool

        public init(conversation: String, isCloud: Bool) {
            self.conversation = conversation
            self.isCloud = isCloud
        }
    }

    /// The main Chief's conversation on the host it runs on now; nil when none is known.
    public var main: String?
    /// Where each Chief conversation's brain runs.
    public var places: [String: ChiefPlace]
    /// Every listed Chief conversation, each once, in the Home's list order.
    public var conversations: [String]

    public init(main: String? = nil, places: [String: ChiefPlace] = [:], conversations: [String] = []) {
        self.main = main
        self.places = places
        self.conversations = conversations
    }

    /// The list from a Home's Chiefs and the user's cloud Chiefs.
    ///
    /// The main Chief runs where the user picked (`showsPlaced`: the paired server's Chief, else the
    /// Hosted Chief), else on the Mac; with the Mac's Chief the default (`prefersLocal`) it is the Mac's
    /// while listed. Every Chief stays listed; it runs in the cloud when the cloud owner lists it, else
    /// on the Mac.
    ///
    /// - Parameters:
    ///   - chiefs: The Home's Chief conversations in list order (a repeat counts once).
    ///   - local: The Mac's default Chief conversation; counts only when listed.
    ///   - hosted: The Hosted Chief's main conversation.
    ///   - placed: The main conversation of the Chief placed on a paired server.
    ///   - server: That server's name.
    ///   - showsPlaced: The user picked the server's Chief.
    ///   - prefersLocal: The default Chief is the Mac's (``ChiefDefault``).
    public init(chiefs: [Chief], local: String?, hosted: String?, placed: String?, server: String?,
                showsPlaced: Bool, prefersLocal: Bool) {
        var seen = Set<String>()
        let unique = chiefs.filter { seen.insert($0.conversation).inserted }
        let local = local.flatMap { seen.contains($0) ? $0 : nil }
        let remote = showsPlaced ? placed ?? hosted : hosted ?? placed
        var places: [String: ChiefPlace] = [:]
        for chief in unique { places[chief.conversation] = chief.isCloud ? .cloud : .thisMac }
        if let local { places[local] = .thisMac }
        if let hosted { places[hosted] = .cloud }
        if let placed { places[placed] = .server(server ?? "") }
        self.init(main: prefersLocal ? local ?? remote : remote ?? local, places: places,
                  conversations: unique.map(\.conversation))
    }

    /// The listed conversations with the main Chief first (pickers, New Message: before a limit can cut it).
    public var mainFirst: [String] {
        guard let main, conversations.contains(main) else { return conversations }
        return [main] + conversations.filter { $0 != main }
    }

    /// The tag after a Chief's name: "Main" for the main Chief, then where it runs ("Main · Cloud"),
    /// since the same Chief can be listed on more than one host; a non-default engine follows
    /// ("This Mac · UniiChat"). Nil when there is nothing to say.
    /// - Parameters:
    ///   - id: The Chief's conversation.
    ///   - engine: Its engine badge, when not the default engine.
    ///   - mainLabel: The localized "Main".
    ///   - label: Each place's localized label (the Mac's list says "This Mac", the iPhone the Mac's name).
    public func tag(for id: String, engine: String?, mainLabel: String, label: (ChiefPlace) -> String?) -> String? {
        let parts = [id == main ? mainLabel : nil, places[id].flatMap(label), engine]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// This list while the cloud Chiefs are not read yet (launch): the last launch's main Chief and
    /// places for the Chiefs listed now, so the first frame does not tag them "This Mac" and move
    /// "Main" when the read lands. A Chief the last launch did not know keeps this list's place.
    /// - Parameter keepsMain: this list's Main is the user's current choice and the last launch's
    ///   must not replace it (the Mac is picked and its Chief is listed).
    public func launching(last: ChiefList, keepsMain: Bool = false) -> ChiefList {
        var places = self.places
        for id in places.keys { if let place = last.places[id] { places[id] = place } }
        let cached = last.main.flatMap { places[$0] != nil ? $0 : nil }
        let main = keepsMain ? self.main ?? cached : cached ?? self.main
        return ChiefList(main: main, places: places, conversations: conversations)
    }
}

/// A cloud Chief record (`chief.list`) as the list's rules read it; the Mac's and the iPhone's
/// `CloudChief` both conform, so both pick the Hosted and the placed Chief by the same rule.
public protocol ChiefListCloudChief {
    /// Its main conversation; nil before it has one.
    var mainConversation: String? { get }
    /// The account's default (primary) Chief.
    var isDefault: Bool { get }
    /// Its brain runs on a paired server (`brain_place`), not in the cloud.
    var isPlaced: Bool { get }
}

extension ChiefList {
    /// The Hosted Chief: the active Chief with no machine placed and a main conversation, the default
    /// one first.
    public static func hosted<C: ChiefListCloudChief>(in chiefs: [C]) -> C? {
        let hosted = chiefs.filter { !$0.isPlaced && $0.mainConversation != nil }
        return hosted.first(where: \.isDefault) ?? hosted.first
    }

    /// The Chief whose brain runs on a server: the default one when it is placed, else the first placed one.
    public static func placed<C: ChiefListCloudChief>(in chiefs: [C]) -> C? {
        let placed = chiefs.filter(\.isPlaced)
        return placed.first(where: \.isDefault) ?? placed.first
    }

    /// Every cloud Chief with a main conversation, as the list's cloud-owned Chiefs.
    public static func cloudChiefs<C: ChiefListCloudChief>(_ chiefs: [C]) -> [Chief] {
        chiefs.compactMap { $0.mainConversation.map { Chief(conversation: $0, isCloud: true) } }
    }
}
