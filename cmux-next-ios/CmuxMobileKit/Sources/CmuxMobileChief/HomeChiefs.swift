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
    ///   - macRows: The Mac's Home rows shown (its `home-inbox`, minus rows hidden here); nil before they arrive.
    ///   - macChief: The Mac's own Chief conversation (its session's, else the one its list names).
    ///   - cloud: The account's Cloud Chiefs (`chief.list`, archived ones already left out).
    ///   - open: The Cloud Chief this phone has open: a placed one is the user's pick, as the Mac's Chief tab choice.
    init(macRows: [MacHomeRow]?, macChief: String?, cloud: [CloudChief], open: CloudChief?) {
        var mac = (macRows ?? []).filter { $0.kind == .chief }.map { ChiefList.Chief(conversation: $0.id, isCloud: false) }
        // Before the Mac's list arrives its Chief stays listed (Home shows it), as the Mac's own list does.
        if macRows == nil, let macChief { mac.append(ChiefList.Chief(conversation: macChief, isCloud: false)) }
        let placed = ChiefList.placed(in: cloud)
        // The Mac's Engine row is not on the wire: Auto, whose answer is the Mac's Chief while that
        // Mac's Chief answers (its conversation is listed), else the cloud Chief.
        let listed = macChief.map { id in mac.contains { $0.conversation == id } } ?? false
        list = ChiefList(chiefs: mac + ChiefList.cloudChiefs(cloud), local: macChief,
                         hosted: ChiefList.hosted(in: cloud)?.mainConversation, placed: placed?.mainConversation,
                         server: placed?.brainPlace?.host, showsPlaced: open?.isPlaced == true,
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
