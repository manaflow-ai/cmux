import AppKit
import SwiftUI

/// Resolves the bundled agent marks custom sidebars may draw instead of SF Symbols.
@MainActor
struct DSLBundledImageResolver {
    private let namespaces: [String]
    private let loadImage: (String) -> NSImage?

    init(
        bundle: Bundle = .main,
        namespaces: [String] = ["AgentIcons/"],
        loadImage: ((String) -> NSImage?)? = nil
    ) {
        self.namespaces = namespaces
        self.loadImage = loadImage ?? { bundle.image(forResource: $0) }
    }

    /// Returns an existing asset name only within the allowed namespaces.
    func assetName(_ name: String?) -> String? {
        guard let name, isAllowed(name), loadImage(name) != nil else { return nil }
        return name
    }

    /// Loads an allowed asset from the resolver's bundle.
    func bundledImage(_ name: String?) -> Image? {
        guard let name, isAllowed(name), let image = loadImage(name) else { return nil }
        return Image(nsImage: image)
    }

    /// Resolves a bundled mark, an SF Symbol, or the empty-name placeholder.
    func image(_ name: String?) -> Image {
        bundledImage(name) ?? Image(systemName: name ?? "questionmark.square.dashed")
    }

    private func isAllowed(_ name: String) -> Bool {
        namespaces.contains { name.hasPrefix($0) && name.count > $0.count }
    }
}
