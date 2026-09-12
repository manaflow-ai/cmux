import Foundation

/// A named color in the chrome design-token system.
///
/// Tokens are deliberately semantic rather than component-specific. This
/// lets the same palette feed the sidebar, tab strip, agent surfaces, and
/// notification chrome without introducing per-view color constants.
public enum ChromeToken: String, CaseIterable, Sendable, Hashable {
    /// Primary interactive accent and selection color.
    case accent
    /// Low-emphasis accent wash for backgrounds and hints.
    case accentSoft
    /// Base chrome surface.
    case surface
    /// Elevated chrome surface such as cards and controls.
    case surfaceRaised
    /// Selected-row or selected-tab surface.
    case surfaceSelected
    /// Pointer-hover surface.
    case surfaceHover
    /// Highest-emphasis chrome text.
    case textPrimary
    /// Supporting chrome text.
    case textSecondary
    /// Lowest-emphasis chrome text.
    case textTertiary
    /// Strong divider and outline color.
    case border
    /// Low-emphasis divider and outline color.
    case borderSubtle
    /// Neutral or idle agent state.
    case agentIdle
    /// In-progress agent state.
    case agentWorking
    /// Successful agent state.
    case agentSuccess
    /// Attention or warning agent state.
    case agentWarning
    /// Failed or error agent state.
    case agentError

    /// A localized label suitable for a per-token override editor.
    public var displayName: String {
        switch self {
        case .accent: return String(localized: "chrome.token.accent", defaultValue: "Accent")
        case .accentSoft: return String(localized: "chrome.token.accentSoft", defaultValue: "Accent (subtle)")
        case .surface: return String(localized: "chrome.token.surface", defaultValue: "Surface")
        case .surfaceRaised: return String(localized: "chrome.token.surfaceRaised", defaultValue: "Raised surface")
        case .surfaceSelected: return String(localized: "chrome.token.surfaceSelected", defaultValue: "Selected surface")
        case .surfaceHover: return String(localized: "chrome.token.surfaceHover", defaultValue: "Hover surface")
        case .textPrimary: return String(localized: "chrome.token.textPrimary", defaultValue: "Primary text")
        case .textSecondary: return String(localized: "chrome.token.textSecondary", defaultValue: "Secondary text")
        case .textTertiary: return String(localized: "chrome.token.textTertiary", defaultValue: "Tertiary text")
        case .border: return String(localized: "chrome.token.border", defaultValue: "Border")
        case .borderSubtle: return String(localized: "chrome.token.borderSubtle", defaultValue: "Subtle border")
        case .agentIdle: return String(localized: "chrome.token.agentIdle", defaultValue: "Agent idle")
        case .agentWorking: return String(localized: "chrome.token.agentWorking", defaultValue: "Agent working")
        case .agentSuccess: return String(localized: "chrome.token.agentSuccess", defaultValue: "Agent success")
        case .agentWarning: return String(localized: "chrome.token.agentWarning", defaultValue: "Agent warning")
        case .agentError: return String(localized: "chrome.token.agentError", defaultValue: "Agent error")
        }
    }
}
