/// A failure at a named stage of socket setup, carrying the failing `errno`.
///
/// The `stage` strings are stable identifiers (for example `"bind"`, `"unlink"`,
/// `"open_lock"`, `"existing_path"`) used in telemetry breadcrumbs and consumed
/// by ``SocketListenerPolicy/fallbackSocketPathAfterBindFailure(requestedPath:stage:errnoCode:currentUserID:)``.
/// Do not rename existing stages.
public struct SocketStageFailure: Equatable, Sendable {
    /// The stable identifier of the setup stage that failed.
    public let stage: String
    /// The `errno` reported by the failing call.
    public let errnoCode: Int32

    /// Creates a stage failure.
    ///
    /// - Parameters:
    ///   - stage: The stable identifier of the failing stage.
    ///   - errnoCode: The `errno` reported by the failing call.
    public init(stage: String, errnoCode: Int32) {
        self.stage = stage
        self.errnoCode = errnoCode
    }
}
