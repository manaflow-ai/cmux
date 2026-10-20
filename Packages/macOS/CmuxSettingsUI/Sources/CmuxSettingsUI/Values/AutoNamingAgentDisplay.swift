import CmuxSettings
import SwiftUI

/// User-facing copy for the Auto-Naming Agent picker and its status line.
/// Brand names (Claude Code, Codex, …) are proper nouns and stay verbatim;
/// only the surrounding sentence is localized.
enum AutoNamingAgentDisplay {
    /// Subtitle under the picker describing what the current selection does.
    static func selectionSubtitle(forSlug slug: String) -> String {
        if slug == AutoNamingAgentCatalog.autoSlug || AutoNamingAgentCatalog.summarizerSupported(slug: slug) {
            return String(
                localized: "settings.automation.autoNamingAgent.subtitle",
                defaultValue: "Automatic uses each session's own agent. Other supported agents need their command-line tool on the PATH."
            )
        }
        // An agent from the Other agents section cannot name sessions, so
        // this status replaces the description while it is selected.
        let name = AutoNamingAgentCatalog.displayName(forSlug: slug)
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
        }
    }
}
