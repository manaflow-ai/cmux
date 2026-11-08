import Foundation

/// Produces localized, correctly pluralized transport incident titles.
struct DiagnosticIncidentTitleFormatter: Sendable {
    private let localization: DiagnosticLocalization
    private let presentation: DiagnosticEventPresentation

    init(locale: Locale) {
        self.localization = DiagnosticLocalization(locale: locale)
        self.presentation = DiagnosticEventPresentation(locale: locale)
    }

    func outageTitle(
        event: DiagnosticEvent,
        consecutiveFailures: Int,
        durationSeconds: Int
    ) -> String {
        let failures = failureCount(consecutiveFailures)
        let duration = secondCount(durationSeconds)
        let latest = presentation.summary(event)
        return localization.string(
            "diagnostics.incident.outage",
            defaultValue: "Transport outage: \(failures) over \(duration). Latest: \(latest)"
        )
    }

    func failureTitle(event: DiagnosticEvent, occurrenceCount: Int) -> String {
        let summary = presentation.summary(event)
        guard occurrenceCount > 1 else { return summary }
        let occurrences = occurrenceCountText(occurrenceCount)
        return localization.string(
            "diagnostics.incident.failureWithOccurrences",
            defaultValue: "\(summary) (\(occurrences))"
        )
    }

    private func failureCount(_ value: Int) -> String {
        if value == 1 {
            return localization.string(
                "diagnostics.incident.consecutiveFailures",
                defaultValue: "\(value) consecutive failure"
            )
        }
        return localization.string(
            "diagnostics.incident.consecutiveFailures",
            defaultValue: "\(value) consecutive failures"
        )
    }

    private func secondCount(_ value: Int) -> String {
        if value == 1 {
            return localization.string(
                "diagnostics.duration.seconds",
                defaultValue: "\(value) second"
            )
        }
        return localization.string(
            "diagnostics.duration.seconds",
            defaultValue: "\(value) seconds"
        )
    }

    private func occurrenceCountText(_ value: Int) -> String {
        if value == 1 {
            return localization.string(
                "diagnostics.incident.occurrences",
                defaultValue: "\(value) occurrence"
            )
        }
        return localization.string(
            "diagnostics.incident.occurrences",
            defaultValue: "\(value) occurrences"
        )
    }
}
