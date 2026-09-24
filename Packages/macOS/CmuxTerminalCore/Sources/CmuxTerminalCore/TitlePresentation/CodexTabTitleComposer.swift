import Foundation

/// Composes Codex lifecycle markers without mutating the stable terminal title.
public struct CodexTabTitleComposer: Sendable {
    private let runningMarker: String
    private let idleMarker: String

    /// Creates a composer using cmux's universal, non-linguistic status glyphs.
    ///
    /// The symbols are deliberately shared across locales: they communicate
    /// state by shape, rather than by language. Use the marker-injecting
    /// initializer when a host needs a different visual vocabulary.
    public init() {
        self.init(runningMarker: "\u{25D0} ", idleMarker: "\u{2733} ")
    }

    /// Creates a composer with marker strings supplied by the host.
    ///
    /// - Parameters:
    ///   - runningMarker: The marker prepended while a turn is running.
    ///   - idleMarker: The marker prepended after a turn completes.
    public init(runningMarker: String, idleMarker: String) {
        self.runningMarker = runningMarker
        self.idleMarker = idleMarker
    }

    /// Resolves the display-only presentation for one stable Codex title.
    ///
    /// User-owned titles remain unchanged, but a running session still keeps
    /// the tab's existing loading indicator visible. Auto-generated titles are
    /// not user-owned and therefore receive the lifecycle marker.
    ///
    /// - Parameters:
    ///   - baseTitle: The stable title stored by the workspace.
    ///   - lifecycle: The authoritative Codex lifecycle, when known.
    ///   - hasUserOwnedTitle: Whether a user explicitly claimed the title.
    /// - Returns: A transient tab presentation; `baseTitle` is never mutated.
    public func presentation(
        baseTitle: String,
        lifecycle: CodexTabTitleLifecycle?,
        hasUserOwnedTitle: Bool
    ) -> CodexTabTitlePresentation {
        let title = baseTitle
        guard let lifecycle else {
            return CodexTabTitlePresentation(title: title, isAnimating: false)
        }
        if hasUserOwnedTitle {
            return CodexTabTitlePresentation(
                title: title,
                isAnimating: lifecycle == .running
            )
        }

        switch lifecycle {
        case .running:
            return CodexTabTitlePresentation(
                title: runningMarker + title,
                isAnimating: true
            )
        case .idle:
            return CodexTabTitlePresentation(
                title: idleMarker + title,
                isAnimating: false
            )
        case .needsInput, .unknown:
            return CodexTabTitlePresentation(title: title, isAnimating: false)
        }
    }
}
