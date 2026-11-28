@testable import CmuxNextCloud
import Foundation
import Testing

@Suite struct CloudGitHubLoginConsentTests {
    @Test func disabledSharingSkipsCarrierAuthorization() async {
        let root = URL(fileURLWithPath: "/")
        var daemon = CloudDaemon(baseURL: root, tokens: {
            Issue.record("An opted-out start requested carrier authorization")
            throw CloudAPIError.notSignedIn
        }, teamID: { nil }, appVersion: "test", sendsStackSession: false)
        daemon.machineIO = .init(binary: root.appendingPathComponent("usr/bin/false"),
                                 cacheDirectory: root, work: .init())

        let result = await daemon.carryGitHubLogin("test-machine", if: false)
        #expect(result == nil)
    }
}
