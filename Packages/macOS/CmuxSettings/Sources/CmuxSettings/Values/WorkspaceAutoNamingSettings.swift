import Foundation

/// Resolved workspace/tab auto-naming settings, read synchronously from a
/// `UserDefaults` suite via ``AutomationCatalogSection/workspaceAutoNamingSettings(in:)``.
///
/// Bundles the two `automation.*` keys that drive an auto-naming pass — the
/// enabled flag and the chosen summarizer agent — into one value so a
/// synchronous reader (the socket auto-title probe) derives both in a single
/// catalog read instead of repeating the slug-to-`nil` mapping at each call
/// site.
public struct WorkspaceAutoNamingSettings: Sendable, Equatable {
    /// Whether AI auto-naming is enabled (`automation.workspaceAutoNaming`).
    public let enabled: Bool

    /// The chosen summarizer agent slug, or `nil` when the catalog default
    /// ``AutoNamingAgentCatalog/autoSlug`` sentinel is selected (name each
    /// session with its own agent).
    public let summarizerAgentSlug: String?

    public init(enabled: Bool, summarizerAgentSlug: String?) {
        self.enabled = enabled
        self.summarizerAgentSlug = summarizerAgentSlug
    }
}

extension AutomationCatalogSection {
    /// Reads the workspace/tab auto-naming settings from `defaults`: the
    /// `automation.workspaceAutoNaming` enabled flag and the
    /// `automation.autoNamingAgent` slug, mapping the catalog default
    /// ``AutoNamingAgentCatalog/autoSlug`` sentinel to `nil` (name each session
    /// with its own agent).
    public func workspaceAutoNamingSettings(in defaults: UserDefaults) -> WorkspaceAutoNamingSettings {
        let enabled = workspaceAutoNaming.value(in: defaults)
        let agentSlug = autoNamingAgent.value(in: defaults)
        return WorkspaceAutoNamingSettings(
            enabled: enabled,
            summarizerAgentSlug: agentSlug == AutoNamingAgentCatalog.autoSlug ? nil : agentSlug
        )
    }
}
