import Foundation

/// The tab-only presentation derived from one Codex lifecycle state.
struct CodexTabTitlePresentation: Equatable, Sendable {
    let title: String
    /// Drives Bonsplit's existing animated tab indicator without publishing
    /// per-frame title mutations through Workspace or the sidebar.
    let isAnimating: Bool
}

/// Resolves Codex lifecycle markers without changing the persisted panel title.
struct CodexTabTitleComposer: Sendable {
    static let statusKey = "codex"
    static let runningPrefix = "◐ "
    static let idlePrefix = "✳ "

    /// Composes the display-only title for a Codex terminal tab.
    ///
    /// User-owned titles always win. The base title remains unmodified in the
    /// workspace model; only the returned presentation carries a marker.
    static func presentation(
        baseTitle: String,
        lifecycle: AgentHibernationLifecycleState?,
        hasCustomTitle: Bool
    ) -> CodexTabTitlePresentation {
        let normalizedBaseTitle = baseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = normalizedBaseTitle
        guard !hasCustomTitle, let lifecycle else {
            return CodexTabTitlePresentation(title: title, isAnimating: false)
        }

        switch lifecycle {
        case .running:
            return CodexTabTitlePresentation(
                title: runningPrefix + title,
                isAnimating: true
            )
        case .idle:
            return CodexTabTitlePresentation(
                title: idlePrefix + title,
                isAnimating: false
            )
        case .needsInput, .unknown:
            return CodexTabTitlePresentation(title: title, isAnimating: false)
        }
    }
}
