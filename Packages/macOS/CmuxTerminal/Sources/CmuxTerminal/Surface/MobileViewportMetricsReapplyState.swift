import Foundation

@MainActor
final class MobileViewportMetricsReapplyState {
    static let maxMetricsFollowUpPasses = 4

    private var isApplyingViewportLimit = false
    private var metricsChangePending = false
    private var isDrainingMetricsFollowUp = false

    func cellMetricsDidChange(reapply: () -> Void) {
        guard !isApplyingViewportLimit, !isDrainingMetricsFollowUp else {
            metricsChangePending = true
            return
        }
        reapply()
    }

    func beginViewportLimitApplication() -> Bool {
        guard !isApplyingViewportLimit else { return false }
        isApplyingViewportLimit = true
        return true
    }

    func endViewportLimitApplication(reapply: () -> Void) {
        isApplyingViewportLimit = false
        guard !isDrainingMetricsFollowUp, metricsChangePending else { return }
        isDrainingMetricsFollowUp = true
        var passCount = 0
        while metricsChangePending, passCount < Self.maxMetricsFollowUpPasses {
            metricsChangePending = false
            passCount += 1
            reapply()
        }
        metricsChangePending = false
        isDrainingMetricsFollowUp = false
    }
}
