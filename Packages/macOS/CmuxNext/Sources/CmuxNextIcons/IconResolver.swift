import os
import Synchronization

/// Picks what to draw for an icon name: its pack drawing, else the catalog's
/// SF Symbol, else a placeholder symbol.
public nonisolated enum IconResolver {
    public nonisolated enum Resolved: Hashable, Sendable {
        case drawing([IconLayer])
        case system(String)
    }

    /// The SF Symbol for a name neither the pack nor the catalog knows.
    public static let unknownSymbol = "questionmark.square.dashed"

    private static let reported = Mutex<Set<IconName>>([])

    /// The Cat drawing replaces Line only when `accent` is `.cat` and the
    /// pack has one; Solid stays Solid.
    public static func resolve(
        _ name: IconName,
        style: IconStyle,
        accent: IconAccent = .none,
        pack: IconPack = .bundled,
        catalog: IconCatalog = .bundled
    ) -> Resolved {
        if let drawing = pack.drawing(for: name) {
            return .drawing(drawing.layers(style: style, accent: accent))
        }
        reportMissing(name)
        return .system(catalog.entry(for: name)?.sf ?? unknownSymbol)
    }

    private static func reportMissing(_ name: IconName) {
        let first = reported.withLock { $0.insert(name).inserted }
        if first {
            IconResources.logger.error("icon \(name.rawValue, privacy: .public) is not in the pack; drawing its SF Symbol")
        }
    }
}
