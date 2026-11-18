public import CmuxChiefList
import Foundation

/// Where a Chief's brain runs: the shared ``ChiefPlace`` (CmuxChiefList), the one the iPhone's
/// Home uses too, so both name a Chief's host by the same rule.
public typealias HomeChiefPlace = ChiefPlace

extension ChiefPlace {
    /// The short label the Mac list's tag and the card's switch show: "This Mac", "Cloud", or the
    /// server's name ("Paired server" while it has none).
    @MainActor public var label: String {
        switch self {
        case .thisMac: HomeModelStrings.placeThisMac
        case .cloud: HomeModelStrings.placeCloud
        case .server(let name): name.isEmpty ? HomeModelStrings.placeServer : name
        }
    }
}
