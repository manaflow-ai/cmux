/// Whether NIGHTLY shows the one-time hang report question (the sidebar notice card).
///
/// It asks only a person who has not been asked, has hang reports off, and has not turned off
/// anonymous telemetry (`sendAnonymousTelemetry`): someone who already said no to data
/// collection is not asked again; the Settings switch still turns reports on.
///
/// ```swift
/// HangReportAskPolicy().shouldAsk(alreadyAsked: false, reportsOn: false, telemetryOptIn: true)  // true
/// ```
public nonisolated struct HangReportAskPolicy: Sendable {
    /// Makes the policy.
    public init() {}

    /// - Parameters:
    ///   - alreadyAsked: The question was shown before on this Mac (any answer).
    ///   - reportsOn: `diagnostics.hangReports` is on.
    ///   - telemetryOptIn: The anonymous telemetry choice (on until the person turns it off).
    /// - Returns: Whether to show the question.
    public func shouldAsk(alreadyAsked: Bool, reportsOn: Bool, telemetryOptIn: Bool) -> Bool {
        !alreadyAsked && !reportsOn && telemetryOptIn
    }
}
