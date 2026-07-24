internal import Foundation
public import CmuxSubrouter

extension SubrouterProvider {
    /// The localized display name for provider section headers.
    public var displayName: String {
        switch self {
        case .codex:
            return String(localized: "subrouter.provider.codex", defaultValue: "Codex")
        case .claude:
            return String(localized: "subrouter.provider.claude", defaultValue: "Claude")
        default:
            // Unknown providers surface their wire identifier verbatim.
            return rawValue
        }
    }

    /// The asset-catalog name of the provider's brand mark in the host
    /// app — the same `AgentIcons` set Vault and the session index use —
    /// or `nil` for providers without a bundled mark.
    public var iconAssetName: String? {
        switch self {
        case .codex: return "AgentIcons/Codex"
        case .claude: return "AgentIcons/Claude"
        default: return nil
        }
    }

    /// A localized note about switch side effects, or `nil` when none apply.
    /// Codex switches also rewrite OpenCode and pi credential files.
    public var switchSideEffectNote: String? {
        guard self == .codex else { return nil }
        return String(
            localized: "subrouter.provider.codex.switchNote",
            defaultValue: "Switching also updates OpenCode and pi credentials."
        )
    }
}
