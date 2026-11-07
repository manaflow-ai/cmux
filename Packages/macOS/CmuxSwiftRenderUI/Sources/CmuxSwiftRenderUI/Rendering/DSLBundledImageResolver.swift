import AppKit
import SwiftUI

/// Resolves the bundled agent marks custom sidebars may draw instead of SF Symbols.
@MainActor
struct DSLBundledImageResolver {
    private let namespaces: [String]
    private let bundle: Bundle

    init(
        bundle: Bundle = .main,
        namespaces: [String] = ["AgentIcons/"]
    ) {
        self.namespaces = namespaces
        self.bundle = bundle
    }

    /// Loads an allowed asset from the resolver's bundle.
    func bundledImage(_ name: String?) -> Image? {
        guard let name, isAllowed(name), let image = bundle.image(forResource: name) else { return nil }
        // Source assets can be much larger than a tab mark (Hermes is 1024 px).
        // Size a copy so the bundle's cached image keeps its own size. A copy, not
        // a new image with the same representations, keeps the catalog's
        // light and dark variants switching with the sidebar's appearance.
        guard let mark = image.copy() as? NSImage else { return nil }
        mark.size = NSSize(width: 14, height: 14)
        return Image(nsImage: mark)
    }

    /// Resolves a bundled mark, an SF Symbol, or the empty-name placeholder.
    func image(_ name: String?) -> Image {
        bundledImage(name) ?? Image(systemName: name ?? "questionmark.square.dashed")
    }

    private func isAllowed(_ name: String) -> Bool {
        // One asset name directly inside the namespace: no nested or `..` paths.
        namespaces.contains { namespace in
            guard name.hasPrefix(namespace) else { return false }
            let asset = name.dropFirst(namespace.count)
            return !asset.isEmpty && !asset.contains("/") && !asset.hasPrefix(".")
        }
    }
}
