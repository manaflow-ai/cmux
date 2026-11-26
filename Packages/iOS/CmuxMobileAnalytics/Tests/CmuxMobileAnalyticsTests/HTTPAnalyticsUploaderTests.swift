import Foundation
import Testing

@testable import CmuxMobileAnalytics

@Suite struct HTTPAnalyticsUploaderTests {
    @Test func revokeAndReenableDuringTokenLookupDropsPreRevokeUpload() async {
        let tokenProvider = BlockingAnalyticsTokenProvider()
        let uploader = HTTPAnalyticsUploader(
            apiBaseURL: "http://127.0.0.1:1",
            tokenProvider: tokenProvider
        )
        let event = AnalyticsEvent(
            name: "ios_app_launched",
            properties: [:],
            distinctID: "anonymous-install",
            anonymousID: nil,
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )

        uploader.setUploadsEnabled(true)
        let upload = Task { await uploader.upload([event]) }
        await tokenProvider.accessStarted.wait()
        uploader.setUploadsEnabled(false)
        uploader.setUploadsEnabled(true)
        await tokenProvider.allowAccessToFinish.open()

        #expect(await upload.value == .drop)
    }
}
