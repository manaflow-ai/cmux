@testable import CmuxMobileAnalytics

actor BlockingAnalyticsUploader: AnalyticsUploading {
    nonisolated let uploadStarted = TestGate()
    nonisolated let allowUploadToFinish = TestGate()
    private(set) var identifyCalls = 0

    func upload(_: [AnalyticsEvent]) async -> AnalyticsUploadResult {
        await uploadStarted.open()
        await allowUploadToFinish.wait()
        return .accepted
    }

    func identify(
        userID _: String?,
        anonymousID _: String?,
        properties _: [String: any Sendable]
    ) async -> AnalyticsUploadResult {
        identifyCalls += 1
        return .accepted
    }
}
