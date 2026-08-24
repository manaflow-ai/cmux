import Foundation

/// The Codex lifecycle states that affect terminal-tab presentation.
public enum CodexTabTitleLifecycle: String, Equatable, Sendable {
    /// A Codex turn is actively executing.
    case running
    /// A Codex turn completed and the session is waiting at its prompt.
    case idle
    /// Codex is waiting for user input such as permission or clarification.
    case needsInput
    /// The lifecycle source has not established a more precise state.
    case unknown
}

/// The transient title and loading presentation for one Codex tab.
public struct CodexTabTitlePresentation: Equatable, Sendable {
    /// The title string presented by the tab bar.
    public let title: String
    /// Whether the tab bar should show its existing indeterminate indicator.
    public let isAnimating: Bool

    /// Creates a tab presentation.
    ///
    /// - Parameters:
    ///   - title: The title presented by the tab bar.
    ///   - isAnimating: Whether the tab bar should show its indeterminate indicator.
    public init(title: String, isAnimating: Bool) {
        self.title = title
        self.isAnimating = isAnimating
    }
}

/// Composes Codex lifecycle markers without mutating the stable terminal title.
public struct CodexTabTitleComposer: Sendable {
    private let runningMarker: String
    private let idleMarker: String

    /// Creates a composer with localized marker strings supplied by the host.
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
