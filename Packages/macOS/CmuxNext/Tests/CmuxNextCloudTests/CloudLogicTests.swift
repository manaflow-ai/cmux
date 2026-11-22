@testable import CmuxNextCloud
import Foundation
import Testing

@Suite struct CloudConfigurationTests {
    @Test func releaseBuildIsAlwaysProduction() {
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app", bundled: ["CMUX_VM_API_BASE_URL": "https://example.test"],
                                                process: [:], isDebugBuild: false)
        #expect(config.backend == .production)
        #expect(config.apiBaseURL.absoluteString == "https://cmux.com")
        #expect(config.stackProjectID == CloudConfiguration.productionProjectID)
        #expect(config.keychainService == "com.cmuxterm.app.auth")
        #expect(config.callbackScheme == "cmux")
    }

    @Test func directBackendBuildUsesTheTagStack() {
        let url = "https://cmux-dev-backend-1.tail137216.ts.net:4053/"
        let config = CloudConfiguration.resolve(
            bundleID: "com.cmuxterm.app.debug.nxcloud",
            bundled: ["CMUX_VM_API_BASE_URL": url, "CMUX_DEV_BACKEND_URL": url, "CMUX_AUTH_WWW_ORIGIN": url, "CMUX_TAG": "nxcloud"],
            process: ["CMUX_VM_API_BASE_URL": "http://evil.test"], isDebugBuild: true)
        #expect(config.backend == .development(URL(string: url)!))
        #expect(config.stackProjectID == CloudConfiguration.developmentProjectID)
        #expect(config.keychainService == "com.cmuxterm.app.debug.nxcloud.auth")
        #expect(config.callbackScheme == "cmux-dev-nxcloud")
    }

    @Test func localBackendModeIsReportedAsLocalOnly() {
        let config = CloudConfiguration.resolve(bundleID: "b", bundled: ["CMUX_VM_API_BASE_URL": "http://localhost:3811"],
                                                process: [:], isDebugBuild: true)
        #expect(config.backend == .localOnly(URL(string: "http://localhost:3811")!))
    }

    /// A callback scheme from the environment that cannot form a URL used to trap at sign-in;
    /// it is ignored and the default scheme is used.
    @Test func unusableCallbackSchemeFallsBackToTheDefault() throws {
        let config = CloudConfiguration.resolve(bundleID: "b", bundled: ["CMUX_AUTH_CALLBACK_SCHEME": "bad scheme"],
                                                process: [:], isDebugBuild: true)
        #expect(config.callbackScheme == "cmux-dev")
        let url = config.signInURL(callbackState: "s1")
        #expect(url.path == "/handler/native-sign-in")
    }

    @Test func signInURLNestsTheNativeCallback() throws {
        let config = CloudConfiguration.resolve(bundleID: "b", bundled: ["CMUX_AUTH_WWW_ORIGIN": "https://web.test", "CMUX_TAG": "My Tag"],
                                                process: [:], isDebugBuild: true)
        let url = config.signInURL(callbackState: "s1")
        #expect(url.path == "/handler/native-sign-in")
        let after = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        #expect(after.hasPrefix("https://web.test/handler/after-sign-in"))
        #expect(after.contains("cmux-dev-my-tag://auth-callback?cmux_auth_state%3Ds1") || after.contains("cmux-dev-my-tag"))
    }
}

@Suite struct DogfoodCredentialsTests {
    @Test func prefersDogfoodFileAndNeverMixesSources() {
        let files = [
            "/h/.secrets/cmuxterm-dev.env": "export CMUX_DOGFOOD_STACK_EMAIL=\"a@x\"\nCMUX_UITEST_STACK_EMAIL=u@x\nCMUX_UITEST_STACK_PASSWORD=up\n",
        ]
        let env = ["CMUX_DOGFOOD_STACK_EMAIL": "e@x", "CMUX_DOGFOOD_STACK_PASSWORD": "ep"]
        // The file has a dogfood email without a password: skip it, take the env pair.
        #expect(DogfoodCredentials.resolve(environment: env.merging(["CMUX_DEV_AUTH_ACCOUNT": "e@x"]) { $1 }, home: "/h",
                                           read: { files[$0] }) == DogfoodCredentials(email: "e@x", password: "ep"))
        #expect(DogfoodCredentials.resolve(environment: ["CMUX_DEV_AUTH_PROFILE": "agent", "CMUX_DEV_AUTH_ACCOUNT": "u@x"], home: "/h",
                                           read: { files[$0] }) == DogfoodCredentials(email: "u@x", password: "up"))
        #expect(DogfoodCredentials.resolve(environment: ["CMUX_DEV_AUTH_PROFILE": "bogus"], home: "/h", read: { files[$0] }) == nil)
    }

    /// hmdm1 on cmux-lawrence-2 (2026-10-06): a tagged build signed in
    /// from the machine's own ~/.secrets/cmuxterm-dev.env, whose pair named
    /// another person. Coordinator decision: the ambient files (and shell
    /// exports) sign in only the machine's declared owner account
    /// (~/.config/cmux/dev-account, or CMUX_DEV_AUTH_ACCOUNT); without a
    /// declaration, or on a mismatch, the build starts signed out and says why.
    static let ambient = ["/h/.secrets/cmuxterm-dev.env":
        "CMUX_DOGFOOD_STACK_EMAIL=Other@X\nCMUX_DOGFOOD_STACK_PASSWORD=p\nCMUX_UITEST_STACK_EMAIL=agent@x\nCMUX_UITEST_STACK_PASSWORD=a\n"]

    @Test func withoutADeclaredOwnerTheAmbientFileSignsInNobody() {
        let files = Self.ambient
        let none = DogfoodCredentials.decide(environment: [:], home: "/h", read: { files[$0] })
        #expect(none.credentials == nil)
        #expect(none.refusal == .noDeclaredAccount)
        let profile = DogfoodCredentials.decide(environment: ["CMUX_DEV_AUTH_PROFILE": "personal"], home: "/h", read: { files[$0] })
        #expect(profile.credentials == nil, "an explicit profile still reads the ambient file")
    }

    @Test func theDeclaredOwnerFileAllowsOnlyItsAccount() {
        var files = Self.ambient
        files["/h/.config/cmux/dev-account"] = " other@x \n"
        #expect(DogfoodCredentials.resolve(environment: [:], home: "/h", read: { files[$0] })
            == DogfoodCredentials(email: "Other@X", password: "p"), "the owner's personal pair, case aside")
        #expect(DogfoodCredentials.resolve(environment: ["CMUX_DEV_AUTH_PROFILE": "agent"], home: "/h", read: { files[$0] }) == nil,
                "the agent pair is another account")
        files["/h/.config/cmux/dev-account"] = "me@x"
        let mismatch = DogfoodCredentials.decide(environment: [:], home: "/h", read: { files[$0] })
        #expect(mismatch.credentials == nil)
        #expect(mismatch.refusal == .accountMismatch(found: "Other@X", declared: "me@x"))
    }

    /// CMUX_DEV_AUTH_ACCOUNT declares the account too, and wins over the file.
    @Test func anExpectedAccountRefusesEveryOtherAccount() {
        var files = Self.ambient
        files["/h/.config/cmux/dev-account"] = "other@x"
        #expect(DogfoodCredentials.resolve(environment: ["CMUX_DEV_AUTH_PROFILE": "agent", "CMUX_DEV_AUTH_ACCOUNT": "agent@x"],
                                           home: "/h", read: { files[$0] }) == DogfoodCredentials(email: "agent@x", password: "a"))
        #expect(DogfoodCredentials.resolve(environment: ["CMUX_DEV_AUTH_ACCOUNT": "me@x"], home: "/h", read: { files[$0] }) == nil)
    }
}
