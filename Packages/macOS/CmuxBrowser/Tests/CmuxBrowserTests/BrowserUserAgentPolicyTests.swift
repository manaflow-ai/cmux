import Foundation
import Testing
@testable import CmuxBrowser

@Suite
struct BrowserUserAgentPolicyTests {
    private let policy = BrowserUserAgentPolicy(safariVersion: "26.6")

    @Test func remoteSitesReceiveCurrentSafariCompatibleIdentity() {
        let workspaceURL = URL(string: "https://workspace.google.com/")!
        let enterpriseSSOURL = URL(string: "https://sso.example.com/duo/")!

        #expect(policy.resolution(for: workspaceURL) == .custom(policy.safariCompatibleUserAgent))
        #expect(policy.resolution(for: enterpriseSSOURL) == .custom(policy.safariCompatibleUserAgent))
        #expect(policy.safariCompatibleUserAgent.contains("Version/26.6 Safari/605.1.15"))
    }

    @Test func configuredIdentityOverridesDestinationSpecificPolicy() {
        let configuredUserAgent = "Configured Browser/1.0"
        let paddedUserAgent = " \n\(configuredUserAgent)\t"
        let duoURL = URL(string: "https://api-example.duosecurity.com/frame/v4/auth")!
        let sheetURL = URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!

        #expect(
            policy.resolution(for: duoURL, userAgentOverride: paddedUserAgent)
                == .custom(configuredUserAgent)
        )
        #expect(
            policy.resolution(for: sheetURL, userAgentOverride: configuredUserAgent)
                == .custom(configuredUserAgent)
        )
    }

    @Test func blankConfiguredIdentityPreservesAutomaticPolicy() {
        let duoURL = URL(string: "https://api-example.duosecurity.com/frame/v4/auth")!
        let sheetURL = URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!

        #expect(
            policy.resolution(for: duoURL, userAgentOverride: " \n\t ")
                == .custom(policy.safariCompatibleUserAgent)
        )
        #expect(policy.resolution(for: sheetURL, userAgentOverride: "") == .webKitDefault)
    }

    @Test func configuredIdentityDoesNotApplyToNonWebDestinations() {
        let configuredUserAgent = "Configured Browser/1.0"

        #expect(
            policy.resolution(
                for: URL(string: "about:blank")!,
                userAgentOverride: configuredUserAgent
            ) == .notApplicable
        )
        #expect(
            policy.resolution(
                for: URL(fileURLWithPath: "/tmp/example.html"),
                userAgentOverride: configuredUserAgent
            ) == .notApplicable
        )
    }

    @Test func staleInstalledSafariIsRaisedToCurrentCompatibilityFloor() {
        let stalePolicy = BrowserUserAgentPolicy(safariVersion: "26.4")

        #expect(stalePolicy.safariCompatibleUserAgent.contains("Version/26.6 Safari/605.1.15"))
    }

    @Test func newerInstalledSafariIsNotDowngradedToCompatibilityFloor() {
        let newerPolicy = BrowserUserAgentPolicy(safariVersion: "27.0")

        #expect(newerPolicy.safariCompatibleUserAgent.contains("Version/27.0 Safari/605.1.15"))
    }

    @Test func googleSheetsKeepsEmbeddedWebKitIdentity() {
        let sheetURL = URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        let sheetsRedirectURL = URL(string: "https://sheets.google.com/")!
        let legacyRedirectURL = URL(string: "https://spreadsheets.google.com/")!

        #expect(policy.resolution(for: sheetURL) == .webKitDefault)
        #expect(policy.resolution(for: sheetsRedirectURL) == .webKitDefault)
        #expect(policy.resolution(for: legacyRedirectURL) == .webKitDefault)
    }

    @Test func otherGoogleWorkspaceEditorsRemainSafariCompatible() {
        let documentURL = URL(string: "https://docs.google.com/document/d/example/edit")!
        let presentationURL = URL(string: "https://docs.google.com/presentation/d/example/edit")!

        #expect(policy.resolution(for: documentURL) == .custom(policy.safariCompatibleUserAgent))
        #expect(policy.resolution(for: presentationURL) == .custom(policy.safariCompatibleUserAgent))
    }

    @Test func nonWebDestinationsHaveNoApplicableUserAgentPolicy() {
        #expect(policy.resolution(for: URL(string: "about:blank")!) == .notApplicable)
        #expect(policy.resolution(for: URL(fileURLWithPath: "/tmp/example.html")) == .notApplicable)
    }

    @Test func googleSheetsAndNonWebDestinationsHaveDistinctPolicyOutcomes() {
        let sheetURL = URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        let fileURL = URL(fileURLWithPath: "/tmp/example.html")

        #expect(policy.resolution(for: sheetURL) != policy.resolution(for: fileURL))
    }
}
