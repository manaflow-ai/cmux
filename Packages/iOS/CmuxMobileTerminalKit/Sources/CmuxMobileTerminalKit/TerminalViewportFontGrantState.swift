/// Owns the report-to-acknowledgement transaction for a larger rendered font.
///
/// A font can leave this state only through an exact acknowledgement. A failed
/// request remains rejected until its geometry-derived signature changes.
///
/// ```swift
/// let request = TerminalViewportFontGrantRequest(
///     fontSize: 14,
///     reportColumns: 72,
///     reportRows: 40,
///     sourceEffectiveRows: 32
/// )
/// var state = TerminalViewportFontGrantState()
/// let decision = state.decision(for: request)
/// ```
public struct TerminalViewportFontGrantState: Sendable {
    private var pendingRequest: TerminalViewportFontGrantRequest?
    private var pendingReportID: UInt64?
    private var failedRequest: TerminalViewportFontGrantRequest?

    /// Creates an idle viewport font grant transaction.
    public init() {}

    /// Starts or resumes the transaction for a geometry-derived request.
    ///
    /// - Parameter request: The destination font and viewport capacity to grant.
    /// - Returns: Whether to wait for a report or reject a previously failed request.
    public mutating func decision(
        for request: TerminalViewportFontGrantRequest
    ) -> TerminalViewportFontGrantDecision {
        if failedRequest == request {
            return .reject
        }
        if failedRequest != nil {
            failedRequest = nil
        }
        if pendingRequest == request {
            return .wait(requestNewReport: false)
        }
        pendingRequest = request
        pendingReportID = nil
        return .wait(requestNewReport: true)
    }

    /// Binds the pending request to a matching emitted viewport report.
    ///
    /// - Parameters:
    ///   - reportID: The monotonic identifier assigned to the emitted report.
    ///   - columns: The report's column capacity.
    ///   - rows: The report's row capacity.
    public mutating func bindPendingRequest(
        toReportID reportID: UInt64,
        columns: Int,
        rows: Int
    ) {
        guard pendingRequest?.reportColumns == columns,
              pendingRequest?.reportRows == rows else { return }
        pendingReportID = reportID
    }

    /// Returns whether a report is the acknowledgement source for the pending request.
    ///
    /// - Parameter reportID: The viewport report identifier to inspect.
    /// - Returns: `true` when the pending request is bound to `reportID`.
    public func isAwaitingAcknowledgement(reportID: UInt64) -> Bool {
        pendingReportID == reportID
    }

    /// Releases the destination font when the host reply preserves its safe geometry.
    ///
    /// - Parameters:
    ///   - reportID: The identifier of the viewport report being acknowledged.
    ///   - columns: The effective host column count.
    ///   - rows: The effective host row count.
    /// - Returns: The destination font size when the acknowledgement is sufficient.
    public mutating func consumeAcknowledgement(
        reportID: UInt64,
        columns: Int,
        rows: Int
    ) -> Float32? {
        guard let pendingRequest,
              pendingReportID == reportID,
              columns > 0,
              columns <= pendingRequest.reportColumns,
              rows == pendingRequest.sourceEffectiveRows else { return nil }
        self.pendingRequest = nil
        pendingReportID = nil
        failedRequest = nil
        return pendingRequest.fontSize
    }

    /// Records a missing or insufficient acknowledgement for a bound report.
    ///
    /// - Parameters:
    ///   - reportID: The identifier of the report that failed.
    ///   - willRetry: Whether the caller will re-emit the same request.
    public mutating func noteReportFailure(reportID: UInt64, willRetry: Bool) {
        guard let pendingRequest, pendingReportID == reportID else { return }
        if willRetry {
            pendingReportID = nil
        } else {
            failedRequest = pendingRequest
            self.pendingRequest = nil
            pendingReportID = nil
        }
    }

    /// Cancels the pending request while retaining the last failed signature.
    public mutating func cancelPendingRequest() {
        pendingRequest = nil
        pendingReportID = nil
    }

    /// Clears pending and failed transaction state.
    public mutating func reset() {
        pendingRequest = nil
        pendingReportID = nil
        failedRequest = nil
    }
}
