import AppKit
import SwiftUI

/// cmux-bundled images a custom sidebar may name in `Image(...)` in place of
/// an SF Symbol, e.g. `Image("AgentIcons/Codex")` - the agent marks cmux
/// shows on terminal tabs. The data context hands out these names as
/// `agents[j].icon` and `tabs[k].agentIcon`.
///
/// Only the listed asset-catalog namespaces resolve, so a sidebar cannot
/// probe arbitrary app images; any other name stays an SF Symbol.
enum DSLBundledImage {
    static let namespaces = ["AgentIcons/"]

    /// The bundled asset `name` names, or `nil` when it is not in an allowed
    /// namespace or `exists` reports no such image.
    static func assetName(
        _ name: String?,
        exists: (String) -> Bool = { NSImage(named: $0) != nil }
    ) -> String? {
        guard let name,
              namespaces.contains(where: { name.hasPrefix($0) && name.count > $0.count }),
              exists(name) else { return nil }
        return name
    }

    /// `Image` for `name`: the bundled asset when it resolves, else the SF
    /// Symbol of that name, else a placeholder symbol.
    static func image(_ name: String?) -> Image {
        if let asset = assetName(name) {
            return Image(asset, bundle: .main)
        }
        return Image(systemName: name ?? "questionmark.square.dashed")
    }
}
