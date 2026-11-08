/// Decides whether a child exit is a startup failure that must remain visible.
public struct TerminalChildExitPolicy: Sendable {
    private let abnormalRuntimeMilliseconds: UInt64

    /// Creates a policy matching Ghostty's configured abnormal-exit threshold.
    ///
    /// - Parameter abnormalRuntimeMilliseconds: The maximum runtime Ghostty
    ///   classifies as an abnormal command exit.
    public init(abnormalRuntimeMilliseconds: UInt32) {
        self.abnormalRuntimeMilliseconds = UInt64(abnormalRuntimeMilliseconds)
    }

    /// Returns whether Ghostty should retain the surface and render its error state.
    ///
    /// - Parameter runtimeMilliseconds: How long the child process survived.
    /// - Returns: `true` for startup failures; `false` for established-process exits.
    public func shouldKeepSurfaceVisible(runtimeMilliseconds: UInt64) -> Bool {
        runtimeMilliseconds <= abnormalRuntimeMilliseconds
    }
}
