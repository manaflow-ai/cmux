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
        // Give each sidebar its own point size without mutating the bundle's image.
        let mark = NSImage(size: NSSize(width: 14, height: 14))
        mark.addRepresentations(image.representations)
        mark.isTemplate = image.isTemplate
        return Image(nsImage: mark)
    }

    /// Resolves a bundled mark, an SF Symbol, or the empty-name placeholder.
    func image(_ name: String?) -> Image {
        bundledImage(name) ?? Image(systemName: name ?? "questionmark.square.dashed")
    }

    private func isAllowed(_ name: String) -> Bool {
        namespaces.contains { name.hasPrefix($0) && name.count > $0.count }
    }
}
