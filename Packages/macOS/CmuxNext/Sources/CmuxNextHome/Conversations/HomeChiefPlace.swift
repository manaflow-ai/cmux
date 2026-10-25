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
        case .thisMac: HomeConversationStrings.placeThisMac
        case .cloud: HomeConversationStrings.placeCloud
        case .server(let name): name
        }
    }
}
