import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A built-in agent logo that can be used as a workspace avatar. The `rawValue`
/// is the stable identifier that travels over the wire inside the `"logo:<id>"`
/// avatar string (see ``MacAvatarIcon``), so it must never change once shipped.
///
/// The macOS app offers the same identifiers in its workspace context-menu
/// avatar picker (`Sources/WorkspaceAvatarCatalog.swift`). Keep the two lists in
/// sync when adding a logo.
public enum WorkspaceAgentLogo: String, CaseIterable, Sendable {
    case claude
    case codex
    case opencode
    case pi
    case terminal

    /// Name of the bundled image asset for this logo.
    var assetName: String {
        switch self {
        case .claude: return "AgentLogoClaude"
        case .codex: return "AgentLogoCodex"
        case .opencode: return "AgentLogoOpencode"
        case .pi: return "AgentLogoPi"
        case .terminal: return "AgentLogoTerminal"
        }
    }

    /// Short monogram shown by the fallback badge when this logo's bundled image
    /// asset cannot be loaded at runtime (see ``WorkspaceAgentLogoImage``).
    var monogram: String {
        switch self {
        case .claude: return "C"
        case .codex: return "Cx"
        case .opencode: return "OC"
        case .pi: return "\u{03C0}"
        case .terminal: return ">_"
        }
    }
}

/// Renders a built-in agent logo, or a neutral monogram badge when the
/// identifier is not a known/bundled logo, sized to fill an avatar circle.
struct WorkspaceAgentLogoImage: View {
    let identifier: String
    let size: Double

    var body: some View {
        if let logo = WorkspaceAgentLogo(rawValue: identifier), Self.assetIsLoadable(logo.assetName) {
            Image(logo.assetName, bundle: .module)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: CGFloat(size), height: CGFloat(size))
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            // A readable badge, never a blank circle: a known logo whose bundled
            // asset failed to load falls back to its monogram; an unknown
            // identifier (e.g. a logo added by a newer client) uses its first
            // letter.
            let text = WorkspaceAgentLogo(rawValue: identifier)?.monogram
                ?? String(identifier.prefix(1)).uppercased()
            Text(text)
                .font(.system(size: CGFloat(size) * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: CGFloat(size), height: CGFloat(size))
                .background(Color.gray, in: Circle())
                .accessibilityHidden(true)
        }
    }

    /// Whether the named asset actually resolves in this module's bundle.
    /// `Image(_:bundle:)` renders an empty view for a missing asset, so probe with
    /// UIImage first and fall back to the monogram badge when it is absent.
    /// Internal (not private) so the resolution test can assert the same lookup.
    static func assetIsLoadable(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(named: name, in: .module, compatibleWith: nil) != nil
        #else
        return true
        #endif
    }
}
