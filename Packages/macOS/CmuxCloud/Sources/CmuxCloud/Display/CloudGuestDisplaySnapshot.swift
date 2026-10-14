import CmuxSurfaceCatalogModel
import Foundation

/// A guest-issued catalog. Connection targets are derived from validated guest
/// slots and the authenticated provider's VM address, never from a guest URL.
public struct CloudGuestDisplaySnapshot: Decodable, Sendable {
    public let version: Int
    public let canCreate: Bool
    public let displays: [CloudGuestDisplay]
    public let created: String?
    public let error: String?

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        // The guest helper currently ships the display slot contract as
        // RFB 5900+n and noVNC 6900+n. These are image compatibility values;
        // the Cloud runtime metadata advertises the primary noVNC port for
        // routing, while a future image that changes this pairing must extend
        // the contract before this validation can be relaxed.
        guard version == 1, !displays.isEmpty, displays.count <= 16,
              Set(displays.map(\.id)).count == displays.count,
              displays.contains(where: { $0.number == 1 }),
              displays.allSatisfy({ (1...16).contains($0.number) && $0.id == "display:\($0.number)" && $0.port == 6900 + $0.number }),
              created == nil || (displays.contains(where: { $0.id == created }) && created != "display:1") else {
            throw SurfaceCatalogError.unsupported(Self.unavailableMessage)
        }
    }

    public static var unavailableMessage: String {
        String(localized: "cloud.display.creationUnavailable", defaultValue: "Additional displays are unavailable on this machine. Use a desktop image with display creation support, then refresh Displays.")
    }
}
