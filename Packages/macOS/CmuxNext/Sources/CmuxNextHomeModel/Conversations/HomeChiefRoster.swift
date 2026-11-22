public import CmuxHomeCore
import CmuxChiefList
import Foundation

/// The user's Chiefs as the Home list shows them: every Chief on every host
/// at once (Lawrence 2026-10-20: "we need to be able to support both local
/// chiefs and cloud chiefs and mac mini chiefs etc all at the same time"),
/// one of them pinned first and tagged "Main" (2026-10-19: "i dont like that
/// i have a ton of chiefs, idk which is main one"), each tagged with where it
/// runs. No host's Chief is hidden: this Mac's Chief keeps running after its
/// history is copied to the Hosted Chief, and the list is the only way back to it.
public nonisolated struct HomeChiefRoster: Hashable, Sendable, Codable {
    /// The main Chief's conversation on the host it runs on now; nil when none is known.
    public var main: ConversationID?
    /// Where each Chief conversation's brain runs.
    public var places: [ConversationID: HomeChiefPlace]

    /// - Parameters:
    ///   - main: The main Chief's conversation.
    ///   - places: Where each Chief conversation runs.
    public init(main: ConversationID? = nil, places: [ConversationID: HomeChiefPlace] = [:]) {
        self.main = main
        self.places = places
    }

    /// The roster from the list's rows and the user's cloud Chiefs.
    ///
    /// The main Chief runs where the user picked (`showsPlaced`: the paired
    /// server's Chief, else the Hosted Chief), else on this Mac. Every Chief
    /// row stays listed; it runs in the cloud when `cloud` lists it, else on
    /// this Mac.
    ///
    /// - Parameters:
    ///   - rows: The list's rows; only Chief rows count.
    ///   - local: This Mac's default Chief conversation.
    ///   - hosted: The Hosted Chief's main conversation.
    ///   - placed: The main conversation of the Chief placed on a paired server.
    ///   - server: That server's name.
    ///   - showsPlaced: The user picked the server's Chief.
    ///   - cloud: The cloud owner's conversations.
    ///   - prefersLocal: The default Chief is this Mac's (``HomeChiefDefault``): it is main when listed.
    /// - Returns: The roster.
    @MainActor public static func make(rows: [InboxRow], local: ConversationID?, hosted: ConversationID?, placed: ConversationID?,
                                       server: String?, showsPlaced: Bool, cloud: Set<ConversationID> = [],
                                       prefersLocal: Bool = false) -> HomeChiefRoster {
        // The one Chief list rule (CmuxChiefList), the iPhone's Home's too.
        let chiefs = rows.filter { $0.kind == .chief }.map { ChiefList.Chief(conversation: $0.id.rawValue, isCloud: cloud.contains($0.id)) }
        // A server with no name yet is "Paired server", as this list always said.
        return HomeChiefRoster(ChiefList(chiefs: chiefs, local: local?.rawValue, hosted: hosted?.rawValue, placed: placed?.rawValue,
                                         server: server, showsPlaced: showsPlaced, prefersLocal: prefersLocal),
                               unnamedServer: HomeModelStrings.placeServer)
    }

    /// This roster as the shared list (CmuxChiefList's ``ChiefList``).
    var list: ChiefList {
        ChiefList(main: main?.rawValue, places: Dictionary(uniqueKeysWithValues: places.map { ($0.key.rawValue, $0.value.shared) }))
    }

    init(_ list: ChiefList, unnamedServer: String = "") {
        self.init(main: list.main.map { ConversationID($0) },
                  places: Dictionary(uniqueKeysWithValues: list.places.map { (ConversationID($0.key), HomeChiefPlace($0.value, unnamedServer: unnamedServer)) }))
    }

    /// This roster while the cloud Chiefs are not read yet (launch): the last launch's main Chief and
    /// places for the Chiefs listed now, so the first frame does not tag them "This Mac" and move
    /// "Main" when the read lands. A Chief the last launch did not know keeps this roster's place.
    /// - Parameter keepsMain: this roster's Main is the user's current choice and the last launch's
    ///   must not replace it (This Mac is picked and its Chief is listed). A cloud read that fails
    ///   leaves the caller on this path for the whole launch, so a cached cloud Main would stay.
    public func launching(last: HomeChiefRoster, keepsMain: Bool = false) -> HomeChiefRoster {
        HomeChiefRoster(list.launching(last: last.list, keepsMain: keepsMain))
    }

    /// The list's tag after a Chief's name: where it runs, after "Main" for
    /// the main Chief ("Main · Cloud"), since the same Chief can be listed
    /// on more than one host; a non-default engine follows ("This Mac · UniiChat").
    @MainActor public func tag(for id: ConversationID, engine: String?) -> String? {
        list.tag(for: id.rawValue, engine: engine, mainLabel: HomeModelStrings.mainChief) { HomeChiefPlace($0, unnamedServer: "").label }
    }
}
