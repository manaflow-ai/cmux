/// Decides what a command-click on terminal text should do about GitHub
/// references, without touching a view, a pane, or `git`.
///
/// The view's job is then only to supply the line under the pointer and to act
/// on the answer. That split matters because the interesting decision here is
/// not "is this token a reference" (``TerminalGitHubReferenceDetector`` owns
/// that) but "is it worth reading the pane's repository to find out", which is
/// what keeps an ordinary word under a cmd-click from costing a `git` call.
public struct TerminalGitHubReferenceClickPolicy: Sendable {
    /// What the caller should do with a command-click.
    public enum Decision: Equatable, Sendable {
        /// Nothing here for GitHub. The click belongs to whatever else the
        /// caller does with it.
        case ignore
        /// Open this reference now. It named its own repository, so no lookup
        /// is needed.
        case open(TerminalGitHubReference)
        /// The token reads as a reference but needs the pane's repository.
        /// Resolve the repository, then call
        /// ``decision(inVisibleLine:column:repositorySlug:)``.
        case resolveRepository
    }

    private let detector: TerminalGitHubReferenceDetector

    /// Creates a policy.
    ///
    /// - Parameter detector: The recognizer to consult. Defaults to the
    ///   standard one.
    public init(detector: TerminalGitHubReferenceDetector = TerminalGitHubReferenceDetector()) {
        self.detector = detector
    }

    /// What to do with a command-click, before any repository is known.
    ///
    /// - Parameters:
    ///   - runtimeOutcome: How the terminal runtime handled the release. Only
    ///     an unhandled release is ours: when the runtime opened a URL or
    ///     consumed the click, acting on it as well would open two things.
    ///   - line: The visible line under the pointer, or `nil` when the caller
    ///     could not read one.
    ///   - column: The zero-based column under the pointer.
    /// - Returns: The decision.
    public func decision(
        runtimeOutcome: TerminalCommandClickRuntimeOutcome,
        inVisibleLine line: String?,
        column: Int
    ) -> Decision {
        guard runtimeOutcome == .unhandled, let line else { return .ignore }

        if let reference = detector.reference(inVisibleLine: line, column: column, repositorySlug: nil) {
            return .open(reference)
        }
        guard detector.needsRepositorySlug(inVisibleLine: line, column: column) else { return .ignore }
        return .resolveRepository
    }

    /// What to do once the pane's repository is known.
    ///
    /// - Parameters:
    ///   - line: The visible line captured when the click happened, not
    ///     re-read afterwards: the pane may have scrolled while `git` ran.
    ///   - column: The zero-based column captured when the click happened.
    ///   - repositorySlug: The pane's `owner/name` repository, or `nil` when it
    ///     has no GitHub remote.
    /// - Returns: ``Decision/open(_:)`` or ``Decision/ignore``. Never
    ///   ``Decision/resolveRepository``: the lookup already happened.
    public func decision(
        inVisibleLine line: String,
        column: Int,
        repositorySlug: String?
    ) -> Decision {
        guard let slug = repositorySlug,
              let reference = detector.reference(
                  inVisibleLine: line,
                  column: column,
                  repositorySlug: slug
              ) else { return .ignore }
        return .open(reference)
    }
}
