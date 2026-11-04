import Foundation
@testable import CmuxNextCloud
import Testing

struct CloudRuntimeSelectionTests {
    @Test func rustSelectionRoutesAllNextConsumersAndScopesAuth() throws {
        let data = Data(#"""
        {"name":"staging","api_origin":"https://backend.standin.invalid","auth_web_origin":"https://signin.standin.invalid",
        "vm_origin":"https://vm.standin.invalid","platform_origin":"https://platform.standin.invalid",
        "mobile_origin":"https://mobile.standin.invalid","device_hub_origin":"https://hub.standin.invalid",
        "share_room_origin":"https://room.standin.invalid","share_api_origin":"https://share.standin.invalid",
        "stack_origin":"https://stack.standin.invalid","stack_project_id":"staging-project","stack_client_key":"staging-key",
        "bundle_id":"com.cmuxterm.app.debug.next","mutable":true,"auth_namespace":"staging-2","legacy_storage":false}
        """#.utf8)
        let selection = try CloudRuntimeSelection.decode(data)
        let configuration = CloudConfiguration.from(selection: selection, bundleID: selection.bundleId,
            bundled: ["CMUX_AUTH_CALLBACK_SCHEME": "cmux-test-callback", "CMUX_STACK_PROJECT_ID": "wrong-project"],
            process: ["CMUX_AUTH_WWW_ORIGIN": "https://wrong.invalid", "CMUX_VM_API_BASE_URL": "https://wrong.invalid"],
            isDebugBuild: false)
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
        #expect(configuration.callbackScheme == "cmux-test-callback")
        #expect(configuration.apiBaseURL == selection.apiOrigin)
        #expect(configuration.stackBaseURL == selection.stackOrigin)
        #expect(configuration.backend == .development(selection.apiOrigin))
        #expect(configuration.linkSource == .appServer)
        #expect(configuration.acceptsShareAPI(selection.shareApiOrigin))
        #expect(!configuration.acceptsShareAPI(URL(string: "https://cloud-api.cmux.dev") ?? selection.shareApiOrigin))
        var otherBackend = selection
        otherBackend.authNamespace = "other-backend"
        otherBackend.legacyStorage = true
        let other = CloudConfiguration.from(selection: otherBackend, bundleID: selection.bundleId,
            bundled: [:], process: [:], isDebugBuild: false)
        #expect(otherBackend.storageNamespace == "other-backend")
        #expect(other.keychainService != configuration.keychainService)
        #expect(other.credentialsDirectory != configuration.credentialsDirectory)
        #expect(other.authDefaultsKey("cmux.auth.hasTokens") != configuration.authDefaultsKey("cmux.auth.hasTokens"))

        var local = selection
        local.name = "local"
        local.apiOrigin = try #require(URL(string: "http://localhost:8787"))
        let localConfiguration = CloudConfiguration.from(selection: local, bundleID: selection.bundleId,
            bundled: [:], process: [:], isDebugBuild: false)
        #expect(localConfiguration.backend == .development(local.apiOrigin), "a selected local backend is available")
    }
}
