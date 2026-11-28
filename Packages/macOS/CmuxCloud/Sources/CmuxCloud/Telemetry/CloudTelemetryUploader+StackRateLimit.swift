import CmuxAuthRuntime
import Foundation

extension CloudTelemetryUploader {
    /// Sends sign-in service rate-limit records through this uploader.
    ///
    /// The records go to the Cloud service, not to the sign-in service, so
    /// they still arrive while the sign-in service throttles this network.
    public nonisolated func attach(to telemetry: StackRateLimitTelemetry) {
        telemetry.setSink { [weak self] event in
            guard let self else { return }
            let span = Self.span(for: event)
            Task { await self.enqueueInstanceScoped(span) }
        }
    }

    /// One span per record; the exporter names it `cmux.auth.<event>`.
    nonisolated static func span(for event: StackRateLimitTelemetryEvent) -> CloudTelemetrySpan {
        let trace = VMRequestTraceContext.mint()
        let atMs = Int64(event.date.timeIntervalSince1970 * 1000)
        let attributes: CloudTelemetryAuthAttributes
        let outcome: CloudTelemetrySpan.Outcome
        let attempt: Int
        let httpStatus: Int?
        switch event.kind {
        case let .rateLimited(retryAfterSeconds, backoffSeconds, eventAttempt, bodyKind, endpoint):
            attributes = CloudTelemetryAuthAttributes(
                event: .stackRateLimited,
                phase: event.phase.rawValue,
                retryAfterS: retryAfterSeconds,
                backoffS: backoffSeconds,
                bodyKind: bodyKind,
                endpoint: endpoint
            )
            outcome = .failure
            attempt = eventAttempt
            httpStatus = 429
        case let .recovered(limitedForSeconds):
            attributes = CloudTelemetryAuthAttributes(
                event: .stackRateLimitRecovered,
                phase: event.phase.rawValue,
                limitedForS: limitedForSeconds
            )
            outcome = .success
            attempt = 0
            httpStatus = nil
        }
        var span = CloudTelemetrySpan(
            eventId: UUID().uuidString.lowercased(),
            operationId: UUID().uuidString.lowercased(),
            traceId: trace.traceId,
            spanId: trace.spanId,
            parentSpanId: nil,
            operation: .session,
            phase: .authentication,
            outcome: outcome,
            startedAtMs: atMs,
            endedAtMs: atMs,
            attempt: min(attempt, 10_000),
            failure: outcome == .failure ? .rateLimit : nil,
            httpStatus: httpStatus
        )
        span.auth = attributes
        return span
    }
}
