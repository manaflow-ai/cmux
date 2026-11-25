import CmuxChiefList
import Foundation

/// Where a Chief's brain runs, as the Home list and the Chief's card name it
/// (Lawrence 2026-10-19: "maybe some are living in cloud and mac minis idk
/// this is super confusing"): this Mac, the cloud, or one paired server.
public nonisolated enum HomeChiefPlace: Hashable, Sendable, Codable {
    /// This Mac's own Chief owner (the default Chief before a cloud Chief, or a named local Chief).
    case thisMac
    /// The Hosted Chief: the Cloud brain answers, so it works while the user's Macs are off.
    case cloud
    /// A paired server's install answers; the value is the server's name (or its host id when unnamed).
    case server(String)

    /// The short label the list's tag and the card's switch show: "This Mac", "Cloud", or the server's name.
    @MainActor public var label: String {
        switch self {
        case .thisMac: HomeModelStrings.placeThisMac
        case .cloud: HomeModelStrings.placeCloud
        case .server(let name): name
        }
    }

    /// The shared list's place (CmuxChiefList's ``ChiefPlace``, the iPhone's too): the same cases.
    var shared: ChiefPlace {
        switch self {
        case .thisMac: .thisMac
        case .cloud: .cloud
        case .server(let name): .server(name)
        }
    }

    /// The place the shared list names; a server with no name yet is `unnamedServer`.
    init(_ shared: ChiefPlace, unnamedServer: String) {
        switch shared {
        case .thisMac: self = .thisMac
        case .cloud: self = .cloud
        case .server(let name): self = .server(name.isEmpty ? unnamedServer : name)
        }
    }
}
