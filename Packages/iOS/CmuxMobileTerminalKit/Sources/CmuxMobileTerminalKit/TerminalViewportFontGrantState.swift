/// A destination font and the viewport capacity that must be acknowledged
/// before the font can render without clipping.
public struct TerminalViewportFontGrantRequest: Equatable, Sendable {
    public let fontSize: Float32
    public let reportColumns: Int
    public let reportRows: Int
    public let sourceEffectiveRows: Int

    public init(
        fontSize: Float32,
        reportColumns: Int,
        reportRows: Int,
        sourceEffectiveRows: Int
    ) {
        self.fontSize = fontSize
        self.reportColumns = reportColumns
        self.reportRows = reportRows
        self.sourceEffectiveRows = sourceEffectiveRows
    }
}

public enum TerminalViewportFontGrantDecision: Equatable, Sendable {
    case wait(requestNewReport: Bool)
    case reject
}

/// Owns the report-to-acknowledgement transaction for a larger rendered font.
/// A font can leave this state only through an exact acknowledgement. A failed
/// request remains rejected until its geometry-derived signature changes.
public struct TerminalViewportFontGrantState: Sendable {
    private struct Pending: Sendable {
        let request: TerminalViewportFontGrantRequest
        var reportID: UInt64?
    }

    private var pending: Pending?
    private var failedRequest: TerminalViewportFontGrantRequest?

    public init() {}

    public mutating func decision(
        for request: TerminalViewportFontGrantRequest
    ) -> TerminalViewportFontGrantDecision {
        if failedRequest == request {
            return .reject
        }
        if failedRequest != nil {
            failedRequest = nil
        }
        if pending?.request == request {
            return .wait(requestNewReport: false)
        }
        pending = Pending(request: request, reportID: nil)
        return .wait(requestNewReport: true)
    }

    public mutating func bindPendingRequest(
        toReportID reportID: UInt64,
        columns: Int,
        rows: Int
    ) {
        guard var pending,
              pending.request.reportColumns == columns,
              pending.request.reportRows == rows else { return }
        pending.reportID = reportID
        self.pending = pending
    }

    public func isAwaitingAcknowledgement(reportID: UInt64) -> Bool {
        pending?.reportID == reportID
    }

    public mutating func consumeAcknowledgement(
        reportID: UInt64,
        columns: Int,
        rows: Int
    ) -> Float32? {
        guard let pending,
              pending.reportID == reportID,
              columns > 0,
              columns <= pending.request.reportColumns,
              rows == pending.request.sourceEffectiveRows else { return nil }
        self.pending = nil
        failedRequest = nil
        return pending.request.fontSize
    }

    public mutating func noteReportFailure(reportID: UInt64, willRetry: Bool) {
        guard var pending, pending.reportID == reportID else { return }
        if willRetry {
            pending.reportID = nil
            self.pending = pending
        } else {
            failedRequest = pending.request
            self.pending = nil
        }
    }

    public mutating func cancelPendingRequest() {
        pending = nil
    }

    public mutating func reset() {
        pending = nil
        failedRequest = nil
    }
}
