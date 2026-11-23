public import CmuxChiefList
import Foundation

/// The account's Cloud Chiefs as the shared Chief list rule reads them (CmuxChiefList).
extension CloudChief: ChiefListCloudChief {
    public var isPlaced: Bool { brainPlace != nil }
}

/// The iPhone Home's Chiefs: the Mac's Chief rows and every one of the account's Cloud Chiefs,
/// through the same rule as the Mac's Home (``ChiefList``, which the Mac's `HomeChiefRoster` calls),
/// so both list the same Chiefs, pick the same Main and tag each with where it runs (user
/// 2026-11-17: "make sure that they both display the same exact chief list using the same exact
/// mechanism"). Before, the phone listed only the open Cloud Chief and always called it Main.
struct HomeChiefs: Equatable {
    let list: ChiefList

    /// - Parameters:
    ///   - macRows: The Mac's Home rows (its `home-inbox`, hidden rows too, as the Mac's roster reads them); nil before they arrive.
    ///   - macChief: The Mac's own Chief conversation (its session's, else the one its list names).
    ///   - cloud: The account's Cloud Chiefs (`chief.list`, archived ones already left out).
    ///   - open: The Cloud Chief this phone has open: a placed one is the user's pick, as the Mac's Chief tab choice.
    ///   - serverName: The paired server's name for a host id, nil when this phone does not know it
    ///     (the Mac's rule: the server's name, else its host id).
    init(macRows: [MacHomeRow]?, macChief: String?, cloud: [CloudChief], open: CloudChief?,
         serverName: (String) -> String? = { _ in nil }) {
        // A Mac row that is a cloud Chief's conversation is that cloud Chief, as the Mac's roster marks it.
        let cloudMains = Set(cloud.compactMap(\.mainConversation))
        let mac = (macRows ?? []).filter { $0.kind == .chief }
            .map { ChiefList.Chief(conversation: $0.id, isCloud: cloudMains.contains($0.id)) }
        let macIDs = Set(mac.map(\.conversation))
        // A Cloud Chief the Mac's list also has is listed once, as the Mac's row (Home shows that row).
        let clouds = ChiefList.cloudChiefs(cloud).filter { !macIDs.contains($0.conversation) }
        let placed = ChiefList.placed(in: cloud)
        // Not on the wire: the Mac's Engine row and whether its brain runs. The phone reads Auto, whose
        // answer is the Mac's Chief while the Mac's list has it, else the cloud Chief. Before the list
        // arrives the Mac's Chief is not listed, so a ready Cloud Chief is Main (as before this change).
        let listed = macChief.map(macIDs.contains) ?? false
        list = ChiefList(chiefs: mac + clouds, local: macChief,
                         hosted: ChiefList.hosted(in: cloud)?.mainConversation, placed: placed?.mainConversation,
                         server: placed?.brainPlace.map { serverName($0.host) ?? $0.host }, showsPlaced: open?.isPlaced == true,
                         prefersLocal: ChiefDefault.auto.prefersLocal(localRunning: listed))
    }

    /// The tag after a Chief's name, the Mac's words except "This Mac", which names the Mac here.
    func tag(for conversation: String?, macName: String?) -> String? {
        guard let conversation else { return nil }
        return list.tag(for: conversation, engine: nil, mainLabel: String(localized: "Main")) { place in
            switch place {
            case .thisMac: macName
            case .cloud: String(localized: "Cloud")
            case let .server(name): name.isEmpty ? String(localized: "Paired server") : name
            }
        }
    }

    /// `chiefs` in the list's order: the main Chief first, then the others as given.
    func mainFirst<T>(_ chiefs: [T], conversation: (T) -> String?) -> [T] {
        guard let main = list.main else { return chiefs }
        return chiefs.filter { conversation($0) == main } + chiefs.filter { conversation($0) != main }
    }
}
