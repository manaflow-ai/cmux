import CmuxMobileModel
import Testing

@Suite struct BuildCapabilitiesTests {
    @Test func pushOnlyWhenTheBuildSaysYes() {
        #expect(BuildCapabilities(info: ["CmuxMobilePush": "YES"]).push)
        #expect(!BuildCapabilities(info: ["CmuxMobilePush": "NO"]).push)
        #expect(!BuildCapabilities(info: ["CmuxMobilePush": ""]).push)
        #expect(!BuildCapabilities(info: [:]).push)
    }

    @Test func appleSignInOnlyWhenTheBuildSaysYes() {
        #expect(BuildCapabilities(info: ["CmuxMobileAppleSignIn": "YES"]).appleSignIn)
        #expect(!BuildCapabilities(info: ["CmuxMobileAppleSignIn": "NO"]).appleSignIn)
        #expect(!BuildCapabilities(info: ["CmuxMobilePush": "YES"]).appleSignIn)
        #expect(!BuildCapabilities(info: [:]).appleSignIn)
    }
}
