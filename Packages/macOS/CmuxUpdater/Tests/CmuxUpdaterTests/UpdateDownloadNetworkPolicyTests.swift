import Foundation
import Testing
@testable import CmuxUpdater

@Suite("Update download network policy")
struct UpdateDownloadNetworkPolicyTests {
    @Test func automaticDownloadRejectsExpensiveAndConstrainedPathsByDefault() {
        let request = NSMutableURLRequest(url: URL(string: "https://example.com/cmux.zip")!)

        UpdateDownloadNetworkPolicy(allowsMeteredAutomaticDownloads: false)
            .apply(to: request, userInitiated: false)

        #expect(!request.allowsExpensiveNetworkAccess)
        #expect(!request.allowsConstrainedNetworkAccess)
    }

    @Test func explicitInstallMayUseTheCurrentNetwork() {
        let request = NSMutableURLRequest(url: URL(string: "https://example.com/cmux.zip")!)

        UpdateDownloadNetworkPolicy(allowsMeteredAutomaticDownloads: false)
            .apply(to: request, userInitiated: true)

        #expect(request.allowsExpensiveNetworkAccess)
        #expect(request.allowsConstrainedNetworkAccess)
    }

    @Test func meteredOptInAllowsAutomaticDownload() {
        let request = NSMutableURLRequest(url: URL(string: "https://example.com/cmux.zip")!)

        UpdateDownloadNetworkPolicy(allowsMeteredAutomaticDownloads: true)
            .apply(to: request, userInitiated: false)

        #expect(request.allowsExpensiveNetworkAccess)
        #expect(request.allowsConstrainedNetworkAccess)
    }
}
