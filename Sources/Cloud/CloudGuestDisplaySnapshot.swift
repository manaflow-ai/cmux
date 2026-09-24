import CmuxSurfaceCatalogModel
import Foundation

/// A guest-issued catalog. Connection targets are derived from validated guest
/// slots and the authenticated provider's VM address, never from a guest URL.
struct CloudGuestDisplaySnapshot: Decodable, Sendable {
    let version: Int
    let canCreate: Bool
    let displays: [CloudGuestDisplay]
    let created: String?
    let error: String?

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard version == 1, !displays.isEmpty, displays.count <= 16,
              Set(displays.map(\.id)).count == displays.count,
              displays.contains(where: { $0.number == 1 }),
              displays.allSatisfy({ (1...16).contains($0.number) && $0.id == "display:\($0.number)" && $0.port == 6900 + $0.number }),
              created == nil || (displays.contains(where: { $0.id == created }) && created != "display:1") else {
            throw SurfaceCatalogError.unsupported(Self.unavailableMessage)
        }
    }

    static var unavailableMessage: String {
        String(localized: "cloud.display.creationUnavailable", defaultValue: "Additional displays are unavailable on this machine. Use a desktop image with display creation support, then refresh Displays.")
    }
}
