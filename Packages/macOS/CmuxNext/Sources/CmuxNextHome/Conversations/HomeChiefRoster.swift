public import CmuxHomeCore
import Foundation

/// The user's Chiefs as the Home list shows them (Lawrence 2026-10-19: "i
/// dont like that i have a ton of chiefs, idk which is main one"): one main
/// Chief, pinned first and tagged "Main"; every other Chief tagged with where
/// it runs. The main Chief is one Chief even when it has a conversation on
/// more than one host (this Mac's, the Hosted Chief's, a paired server's):
/// the list shows only the host the user picked (``main``) and leaves the
/// others out (``merged``); its card offers the switch.
public struct HomeChiefRoster: Hashable, Sendable {
    /// The main Chief's conversation on the host it runs on now; nil when none is known.
    public var main: ConversationID?
    /// The main Chief's conversations on its other hosts: the list leaves them out.
    public var merged: Set<ConversationID>
    /// Where each Chief conversation's brain runs.
    public var places: [ConversationID: HomeChiefPlace]

    /// - Parameters:
    ///   - main: The main Chief's shown conversation.
    ///   - merged: The main Chief's other hosts' conversations, left out of the list.
    ///   - places: Where each Chief conversation runs.
    public init(main: ConversationID? = nil, merged: Set<ConversationID> = [], places: [ConversationID: HomeChiefPlace] = [:]) {
        self.main = main
        self.merged = merged
        self.places = places
    }

    /// The roster from the list's rows and the user's cloud Chiefs.
    ///
    /// The main Chief runs where the user picked (`showsPlaced`: the paired
    /// server's Chief, else the Hosted Chief), else on this Mac. This Mac's
    /// Chief merges into the Hosted Chief only when one exists, since its
    /// history was copied there; with a server Chief alone it stays its own
    /// entry, tagged "This Mac". Every other Chief row runs in the cloud when
    /// `cloud` lists it, else on this Mac.
    ///
    /// - Parameters:
    ///   - rows: The list's rows; only Chief rows count.
    ///   - local: This Mac's default Chief conversation.
    ///   - hosted: The Hosted Chief's main conversation.
    ///   - placed: The main conversation of the Chief placed on a paired server.
    ///   - server: That server's name.
    ///   - showsPlaced: The user picked the server's Chief.
    ///   - cloud: The cloud owner's conversations.
    /// - Returns: The roster.
    public static func make(rows: [InboxRow], local: ConversationID?, hosted: ConversationID?, placed: ConversationID?,
                            server: String?, showsPlaced: Bool, cloud: Set<ConversationID> = []) -> HomeChiefRoster {
        let chiefRows = rows.filter { $0.kind == .chief }.map(\.id)
        let listed = Set(chiefRows)
        let local = local.flatMap { listed.contains($0) ? $0 : nil }
        let main = (showsPlaced ? placed ?? hosted : hosted ?? placed) ?? local
        var places: [ConversationID: HomeChiefPlace] = [:]
        for id in chiefRows { places[id] = cloud.contains(id) ? .cloud : .thisMac }
        if let local { places[local] = .thisMac }
        if let hosted { places[hosted] = .cloud }
        if let placed { places[placed] = server.map(HomeChiefPlace.server) ?? .server(HomeConversationStrings.placeServer) }
        var merged = Set([hosted, placed].compactMap { $0 })
        if hosted != nil, let local { merged.insert(local) }
        if let main { merged.remove(main) }
        return HomeChiefRoster(main: main, merged: merged, places: places)
    }

    /// The list's tag after a Chief's name: "Main" for the main Chief, else
    /// where it runs; a non-default engine follows ("Main · UniiChat").
    public func tag(for id: ConversationID, engine: String?) -> String? {
        let first = id == main ? HomeConversationStrings.mainChief : places[id]?.label
        let parts = [first, engine].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
