import AppKit
import Foundation

extension SessionAgent {
    var displayName: String {
        switch self {
        case .claude: return String(localized: "sessionIndex.agent.claude", defaultValue: "Claude Code")
        case .codex: return String(localized: "sessionIndex.agent.codex", defaultValue: "Codex")
        case .grok: return String(localized: "sessionIndex.agent.grok", defaultValue: "Grok")
        case .opencode: return String(localized: "sessionIndex.agent.opencode", defaultValue: "OpenCode")
        case .rovodev: return String(localized: "sessionIndex.agent.rovodev", defaultValue: "Rovo Dev")
        case .registered(let agent):
            return agent.displayName
        case .hermesAgent: return String(localized: "sessionIndex.agent.hermesAgent", defaultValue: "Hermes Agent")
        }
    }

    /// Asset catalog image name for the agent's brand mark.
    var assetName: String? {
        switch self {
        case .claude: return "AgentIcons/Claude"
        case .codex: return "AgentIcons/Codex"
        case .grok: return "AgentIcons/Grok"
        case .opencode: return "AgentIcons/OpenCode"
        case .rovodev: return "AgentIcons/RovoDev"
        case .registered(let agent):
            return agent.iconAssetName
        case .hermesAgent: return "AgentIcons/HermesAgent"
        }
    }

    var systemImageName: String? {
        switch self {
        case .registered:
            return assetName == nil ? "person.crop.circle" : nil
        default:
            return nil
        }
    }
}

extension RestorableAgentKind {
    /// SF Symbol fallback shown for agent kinds that have no bundled brand asset.
    static let fallbackSymbolName = "sparkles.rectangle.stack"

    /// Authoritative asset-catalog image name for an agent kind's bundled brand mark,
    /// or `nil` when no asset ships for the kind. This is the single source of truth for
    /// kind→asset resolution (reconciling the `assetName: nil` inconsistency in
    /// `TaskManagerTypes.swift`; the mapping here wins).
    var agentIconAssetName: String? {
        switch self {
        case .claude: return "AgentIcons/Claude"
        case .codex: return "AgentIcons/Codex"
        case .grok: return "AgentIcons/Grok"
        case .pi: return "AgentIcons/Pi"
        case .antigravity: return "AgentIcons/Antigravity"
        case .opencode: return "AgentIcons/OpenCode"
        case .rovodev: return "AgentIcons/RovoDev"
        case .hermesAgent: return "AgentIcons/HermesAgent"
        case .cursor: return "AgentIcons/Cursor"
        case .amp, .gemini, .kiro, .copilot, .codebuddy, .factory, .qoder:
            return nil
        case .custom(let id):
            // Process detection encodes even built-in agents as `.custom(id)` (e.g. a
            // terminal `claude` CLI surfaces as `.custom("claude")`). Re-resolve the id
            // so a custom kind whose id names a built-in gets that built-in's brand
            // asset; a genuinely third-party id (no matching built-in) has no bundled
            // asset here and falls back (registry-declared icons are resolved by the
            // snapshot-level helper below).
            guard let resolved = RestorableAgentKind(rawValue: id), resolved.customAgentID == nil else {
                return nil
            }
            return resolved.agentIconAssetName
        }
    }

    /// Loads the kind's bundled brand asset resolved for the given appearance and returns
    /// PNG `Data` suitable for a tab's `iconImageData:` channel. Returns `nil` when the kind
    /// has no bundled asset or the image cannot be encoded. The asset catalog resolves
    /// appearance variants (e.g. `Codex-dark`) via the supplied appearance.
    @MainActor
    func agentIconPNGData(appearance: NSAppearance? = nil) -> Data? {
        agentBrandIconPNGData(assetName: agentIconAssetName, appearance: appearance)
    }
}

extension SessionRestorableAgentSnapshot {
    /// Authoritative asset-catalog name for this session's agent brand mark, or `nil`
    /// when no bundled asset applies (render the `sparkles.rectangle.stack` fallback).
    /// Prefers a registry-declared `iconAssetName` (covers custom agents and registry-
    /// owned built-ins such as Pi/Antigravity/Grok), then the kind's built-in mapping.
    var agentIconAssetName: String? {
        if let registrationAsset = registration?.iconAssetName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !registrationAsset.isEmpty {
            return registrationAsset
        }
        return kind.agentIconAssetName
    }

    /// PNG `Data` for this session's brand mark suitable for a tab's `iconImageData:`
    /// channel, or `nil` when no bundled asset applies.
    @MainActor
    func agentIconPNGData(appearance: NSAppearance? = nil) -> Data? {
        agentBrandIconPNGData(assetName: agentIconAssetName, appearance: appearance)
    }
}

/// Shared appearance-correct PNG encoding for agent brand assets. Centralizes the
/// asset→`NSImage`→PNG path so the `RestorableAgentKind`, `SessionRestorableAgentSnapshot`,
/// and `DetectedBuiltInAgent` icon helpers stay in sync.
///
/// Resolves `assetName` to an appearance-correct PNG. Returns `nil` when `assetName`
/// is `nil`, the asset is missing, or the image cannot be encoded. The asset catalog
/// resolves appearance variants (e.g. `Codex-dark`) via the supplied appearance.
@MainActor
func agentBrandIconPNGData(assetName: String?, appearance: NSAppearance? = nil) -> Data? {
    guard let assetName else { return nil }
    guard let image = NSImage(named: assetName) else { return nil }
    let effectiveAppearance = appearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
    var pngData: Data?
    effectiveAppearance.performAsCurrentDrawingAppearance {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return
        }
        pngData = bitmap.representation(using: .png, properties: [:])
    }
    return pngData
}
