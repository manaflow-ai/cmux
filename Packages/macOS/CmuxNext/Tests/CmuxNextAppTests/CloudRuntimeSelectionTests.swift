import Foundation
@testable import CmuxNextCloud
import Testing

struct CloudRuntimeSelectionTests {
    @Test func rustSelectionRoutesAllNextConsumersAndScopesAuth() throws {
        let data = Data(#"""
        {"name":"staging","api_origin":"https://cloud-api-staging.cmux.dev","auth_web_origin":"https://cmux-staging.vercel.app",
        "vm_origin":"https://vm-staging.cmux.dev","platform_origin":"https://cmux-platform-staging.debussy.workers.dev",
        "mobile_origin":"https://cmux-mobile-api-dev.debussy.workers.dev","device_hub_origin":"https://cmux-device-hub-dev.debussy.workers.dev",
        "share_room_origin":"https://cmux-platform-staging.debussy.workers.dev","share_api_origin":"https://cloud-api-staging.cmux.dev",
        "stack_origin":"https://api.stack-auth.com","stack_project_id":"staging-project","stack_client_key":"staging-key",
        "bundle_id":"com.cmuxterm.app.debug.next","mutable":true,"auth_namespace":"staging-2"}
        """#.utf8)
        let selection = try CloudRuntimeSelection.decode(data)
        let baseline = CloudConfiguration.resolve(bundleID: selection.bundleId, bundled: [:], process: [:], isDebugBuild: false)
        let configuration = baseline.applying(selection)
        let overrides = ["CMUX_NEXT_FEED_API_URL": "https://other.invalid", "CMUX_NEXT_ARTIFACTS_API_URL": "https://other.invalid"]
        #expect(configuration.ownerAPIBaseURL(environment: overrides) == selection.apiOrigin)
        #expect(configuration.shareAPIBaseURL(environment: overrides) == selection.shareApiOrigin)
        #expect(configuration.platformPreviewAPIBaseURL(environment: overrides) == selection.platformOrigin)
        #expect(configuration.artifactsAPIBaseURL(environment: overrides) == selection.platformOrigin)
        #expect(configuration.keychainService == "com.cmuxterm.app.debug.next.auth.staging-2")
        #expect(configuration.credentialsDirectory.lastPathComponent == "staging-2")
        #expect(configuration.authDefaultsKey("cmux.auth.hasTokens") == "cmux.auth.hasTokens.staging-2")
        #expect(configuration.stackProjectID == "staging-project")
        #expect(configuration.stackPublishableClientKey == "staging-key")
        #expect(configuration.authWebOrigin == selection.authWebOrigin)
        #expect(configuration.callbackScheme == baseline.callbackScheme)
        #expect(configuration.apiBaseURL == selection.authWebOrigin)
        #expect(configuration.acceptsShareAPI(selection.shareApiOrigin))
        #expect(!configuration.acceptsShareAPI(URL(string: "https://cloud-api.cmux.dev") ?? selection.shareApiOrigin))
    }
}
