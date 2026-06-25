import CmuxSettings
import SwiftUI

/// User-facing copy for the Auto-Naming Agent picker and its status line.
/// Brand names (Claude Code, Codex, …) are proper nouns and stay verbatim;
/// only the surrounding sentence is localized.
enum AutoNamingAgentDisplay {
    /// Subtitle under the picker describing what the current selection does.
    static func selectionSubtitle(forSlug slug: String) -> String {
        if slug == AutoNamingAgentCatalog.autoSlug {
            return String(
                localized: "settings.automation.autoNamingAgent.requirement.auto",
                defaultValue: "Each session is named by its own agent."
            )
        }
        let name = AutoNamingAgentCatalog.displayName(forSlug: slug)
        if AutoNamingAgentCatalog.summarizerSupported(slug: slug) {
            return String(
                localized: "settings.automation.autoNamingAgent.requirement.supported",
                defaultValue: "\(name) names every session. Requires its CLI on your PATH; if it can't produce a name, existing names are left unchanged."
            )
        }
        return String(
            localized: "settings.automation.autoNamingAgent.requirement.unsupported",
            defaultValue: "\(name) can't generate names yet, so cmux uses each session's own agent."
        )
    }

    /// One-line status shown only when the last naming pass hit a problem.
    /// Never appears in a workspace or tab title.
    static func statusMessage(_ status: AutoNamingStatus) -> String {
        let name = AutoNamingAgentCatalog.displayName(forSlug: status.agent)
        switch status.category {
        case .failed:
            return String(
                localized: "settings.automation.autoNamingAgent.status.failed",
                defaultValue: "\(name) couldn't generate a name — it may be rate-limited, out of tokens, or signed out. Existing names are left unchanged."
            )
        case .notInstalled:
            return String(
                localized: "settings.automation.autoNamingAgent.status.notInstalled",
                defaultValue: "\(name) isn't installed, so naming used each session's own agent."
            )
        case .probeFailed:
            return String(
                localized: "settings.automation.autoNamingAgent.status.probeFailed",
                defaultValue: "cmux couldn't read the live auto-naming settings from the app. Existing names are left unchanged."
            )
        case .extractionFailed:
            return String(
                localized: "settings.automation.autoNamingAgent.status.extractionFailed",
                defaultValue: "cmux couldn't read enough conversation text to generate a name. Existing names are left unchanged."
            )
        case .applyFailed:
            return String(
                localized: "settings.automation.autoNamingAgent.status.applyFailed",
                defaultValue: "\(name) generated a name, but cmux couldn't apply it. Existing names are left unchanged."
            )
        }
    }
}
