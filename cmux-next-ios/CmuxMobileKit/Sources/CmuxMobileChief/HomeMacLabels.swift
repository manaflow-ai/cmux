#if os(iOS)
import CmuxMobileModel
import Foundation

/// How Home names where each Chief runs: the Cloud Chief in the account's
/// Cloud, on no Mac; the Chiefs of the Mac's Home list on that Mac (the Mac's
/// list tags them "This Mac"). Macs are named as on Workspaces (same-name Macs
/// carry their tag).
struct HomeMacLabels {
    /// The listed Macs (``MacRoster/visible``).
    let macs: [MacDevice]
    /// The filter, resolved: a Mac that left the team reads as All Macs.
    let scope: MacScope
    private let names: MacNameDisambiguation

    /// - `accountMacs`: every listed Mac on the account (all teams), the scope
    ///   of same-name tags as on Workspaces; nil uses `macs`.
    init(macs: [MacDevice], scope: MacScope, accountMacs: [MacDevice]? = nil) {
        self.macs = macs
        self.scope = MacFilter.resolve(scope, macs: macs)
        names = MacNameDisambiguation(accountMacs ?? macs)
    }

    /// The Mac's name as Workspaces shows it.
    func macName(_ macID: String) -> String? {
        macs.first { $0.id == macID }.map(names.displayName)
    }

    /// Under a Chief pin's name: where that Chief runs.
    func chiefDetail(place: ChiefRoute.Place, macID: String?, macName: String?) -> String? {
        switch place {
        case .cloud: return String(localized: "Cloud")
        case .mac: return macID.flatMap { self.macName($0) } ?? macName
        }
    }
}
#endif
