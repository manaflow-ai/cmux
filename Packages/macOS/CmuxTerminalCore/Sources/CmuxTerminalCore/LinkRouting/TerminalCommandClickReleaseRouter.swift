/// Chooses the one owner of a command-click release after the terminal runtime
/// has processed the mouse event.
public struct TerminalCommandClickReleaseRouter: Sendable {
    /// The terminal runtime's primary handling outcome for the release.
    public enum RuntimeOutcome: Equatable, Sendable {
        /// The runtime did not consume the release.
        case unhandled
        /// The runtime consumed the release without dispatching an open-URL action.
        case consumed
        /// The runtime dispatched an open-URL action for the release.
        case openURL
    }

    /// How cmux resolved a local path candidate under the pointer.
    public enum PathResolutionSource: Equatable, Sendable {
        /// Ghostty's quick-look word supplied the candidate.
        case quicklook
        /// cmux's pointer-anchored terminal snapshot supplied the candidate.
        case snapshot
    }

    /// An existing local path resolved under the pointer.
    public struct ResolvedPath: Equatable, Sendable {
        /// The absolute path to open.
        public let path: String
        /// The terminal-text source that produced the path.
        public let source: PathResolutionSource

        /// Creates a resolved local-path candidate.
        ///
        /// - Parameters:
        ///   - path: The absolute path to open.
        ///   - source: The terminal-text source that produced the path.
        public init(path: String, source: PathResolutionSource) {
            self.path = path
            self.source = source
        }
    }

    /// The exclusive action selected for one command-click release.
    public enum Route: Equatable, Sendable {
        /// Keep the open-URL action already dispatched by the terminal runtime.
        case runtimeOpenURL
        /// Open the resolved local path through cmux's fallback path.
        case pathFallback(ResolvedPath)
        /// Perform no cmux fallback action.
        case none
    }

    /// Creates a command-click release router.
    public init() {}

    /// Resolves one release to exactly one action.
    ///
    /// Path resolution is lazy so primary runtime actions can exclude local
    /// filesystem probing altogether.
    ///
    /// - Parameters:
    ///   - commandHeld: Whether Command was held for the release.
    ///   - pathFallbackSuppressed: Whether selection state suppresses path fallback.
    ///   - runtimeOutcome: The terminal runtime's primary handling outcome.
    ///   - resolvePath: Resolves the local path candidate only when eligible.
    /// - Returns: The exclusive action for the release.
    public func route(
        commandHeld: Bool,
        pathFallbackSuppressed: Bool,
        runtimeOutcome: RuntimeOutcome,
        resolvePath: () -> ResolvedPath?
    ) -> Route {
        guard commandHeld, !pathFallbackSuppressed else { return .none }
        guard let resolution = resolvePath() else { return .none }

        switch runtimeOutcome {
        case .unhandled:
            return .pathFallback(resolution)
        case .consumed, .openURL:
            // Preserve the legacy pointer-snapshot exception while extracting
            // the routing decision. The regression test proves that an explicit
            // open-URL outcome must become the exclusive owner in the fix.
            return resolution.source == .snapshot ? .pathFallback(resolution) : .none
        }
    }
}
