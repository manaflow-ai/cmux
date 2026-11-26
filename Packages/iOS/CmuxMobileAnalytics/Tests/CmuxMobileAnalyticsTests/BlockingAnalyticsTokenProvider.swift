@testable import CmuxMobileAnalytics

actor BlockingAnalyticsTokenProvider: AnalyticsTokenProviding {
    nonisolated let accessStarted = TestGate()
    nonisolated let allowAccessToFinish = TestGate()

    func accessToken() async -> String? {
        await accessStarted.open()
        await allowAccessToFinish.wait()
        return "access-token"
    }

    func refreshToken() async -> String? { nil }
}
