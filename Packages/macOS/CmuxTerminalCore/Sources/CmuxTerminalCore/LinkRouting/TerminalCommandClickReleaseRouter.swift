/// Chooses the one owner of a command-click release after the terminal runtime
/// has processed the mouse event.
public struct TerminalCommandClickReleaseRouter: Sendable {
    /// The terminal runtime's primary handling outcome for the release.
    public typealias RuntimeOutcome = TerminalCommandClickRuntimeOutcome

    /// How cmux resolved a local path candidate under the pointer.
    public typealias PathResolutionSource = TerminalCommandClickPathResolutionSource

    /// An existing local path resolved under the pointer.
    public typealias ResolvedPath = TerminalCommandClickResolvedPath

    /// The exclusive action selected for one command-click release.
    public typealias Route = TerminalCommandClickRoute

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

        switch runtimeOutcome {
        case .unhandled:
            guard let resolution = resolvePath() else { return .none }
            return .pathFallback(resolution)
        case .consumed:
            guard let resolution = resolvePath() else { return .none }
            // Preserve the legacy pointer-snapshot exception for consumed
            // non-URL clicks. An explicit open-URL action is handled below and
            // never reaches local path resolution.
            return resolution.source == .snapshot ? .pathFallback(resolution) : .none
        case .openURL:
            return .runtimeOpenURL
        }
    }
}
