import CmuxCloud
import Foundation

extension VMClientTelemetry {
    /// The production telemetry: PostHog for captured requests, Sentry for
    /// failures and breadcrumbs. Built once at the composition root.
    static func live() -> VMClientTelemetry {
        VMClientTelemetry(
            capturePostHog: { event, properties in
                PostHogAnalytics.shared.capture(event, properties: properties)
            },
            captureSentry: { message, severity, data in
                switch severity {
                case .error:
                    sentryCaptureError(message, category: VMClientTelemetry.sentryCategory, data: data)
                case .warning:
                    sentryCaptureWarning(message, category: VMClientTelemetry.sentryCategory, data: data)
                }
            },
            addBreadcrumb: { message, data in
                sentryBreadcrumb(message, category: VMClientTelemetry.sentryCategory, data: data)
            }
        )
    }
}
