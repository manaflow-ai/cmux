import Foundation

/// The tab-only presentation derived from one Codex lifecycle state.
struct CodexTabTitlePresentation: Equatable, Sendable {
    let title: String
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

        let unmarkedTitle = removingCodexMarker(from: title)
        switch lifecycle {
        case .running:
            return CodexTabTitlePresentation(
                title: runningPrefix + unmarkedTitle,
                isAnimating: true
            )
        case .idle:
            return CodexTabTitlePresentation(
                title: idlePrefix + unmarkedTitle,
                isAnimating: false
            )
        case .needsInput, .unknown:
            return CodexTabTitlePresentation(title: unmarkedTitle, isAnimating: false)
        }
    }

    private static func removingCodexMarker(from title: String) -> String {
        if title.hasPrefix(runningPrefix) {
            return String(title.dropFirst(runningPrefix.count))
        }
        if title.hasPrefix(idlePrefix) {
            return String(title.dropFirst(idlePrefix.count))
        }
        return title
    }
}
