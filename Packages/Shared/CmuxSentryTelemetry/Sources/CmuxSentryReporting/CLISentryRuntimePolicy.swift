public import Sentry

/// Configures Sentry for telemetry emitted by a short-lived CLI process.
///
/// A CLI invocation has no application lifecycle during which a synchronous
/// transport drain is useful. Its events are persisted before the process
/// exits, so SDK shutdown must never add a network wait to the command path.
public struct CLISentryRuntimePolicy: Sendable {
    /// Creates the short-lived CLI policy.
    public init() {}

    /// Applies the CLI lifecycle and shutdown settings to Sentry options.
    ///
    /// - Parameter options: The options that will be passed to
    ///   `SentrySDK.start(options:)`.
    public func configure(_ options: Options) {
        // SentrySDK.close() always asks its transport to flush. Keep that
        // shutdown path bounded even if a future CLI teardown calls close().
        options.shutdownTimeInterval = 0
        options.enableAppHangTracking = false
        options.enableWatchdogTerminationTracking = false
        options.enableAutoSessionTracking = false
        options.enableLogs = false
        options.enableMetricKit = false
    }
}
