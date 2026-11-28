import os
import Synchronization

public nonisolated extension IconPack {
    /// What to draw for `name`: this pack's drawing, else the catalog's SF
    /// Symbol, else a placeholder symbol. The Cat drawing replaces Line only
    /// when `accent` is `.cat` and the pack has one; Solid stays Solid.
    func resolve(
        _ name: IconName,
        style: IconStyle,
        accent: IconAccent = .none,
        catalog: IconCatalog = .bundled
    ) -> IconResolution {
        if let drawing = drawing(for: name) {
            return .drawing(drawing.layers(style: style, accent: accent))
        }
        if Self.reportedMissingIcons.withLock({ $0.insert(name).inserted }) {
            IconResources.logger.error("icon \(name.rawValue, privacy: .public) is not in the pack; drawing its SF Symbol")
        }
        return .system(catalog.entry(for: name)?.sf ?? IconResolution.unknownSymbol)
    }

    private static let reportedMissingIcons = Mutex<Set<IconName>>([])
}
