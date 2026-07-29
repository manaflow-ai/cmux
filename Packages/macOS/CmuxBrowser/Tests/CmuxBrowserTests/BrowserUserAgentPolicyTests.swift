import Foundation
import Testing
@testable import CmuxBrowser

@Suite
struct BrowserUserAgentPolicyTests {
    private let policy = BrowserUserAgentPolicy(safariVersion: "26.6")

    @Test func remoteSitesReceiveCurrentSafariCompatibleIdentity() {
        let workspaceURL = URL(string: "https://workspace.google.com/")!
        let enterpriseSSOURL = URL(string: "https://sso.example.com/duo/")!

        #expect(policy.customUserAgent(for: workspaceURL) == policy.safariCompatibleUserAgent)
        #expect(policy.customUserAgent(for: enterpriseSSOURL) == policy.safariCompatibleUserAgent)
        #expect(policy.safariCompatibleUserAgent.contains("Version/26.6 Safari/605.1.15"))
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

        #expect(policy.customUserAgent(for: sheetURL) == nil)
        #expect(policy.customUserAgent(for: sheetsRedirectURL) == nil)
        #expect(policy.customUserAgent(for: legacyRedirectURL) == nil)
    }

    @Test func otherGoogleWorkspaceEditorsRemainSafariCompatible() {
        let documentURL = URL(string: "https://docs.google.com/document/d/example/edit")!
        let presentationURL = URL(string: "https://docs.google.com/presentation/d/example/edit")!

        #expect(policy.customUserAgent(for: documentURL) == policy.safariCompatibleUserAgent)
        #expect(policy.customUserAgent(for: presentationURL) == policy.safariCompatibleUserAgent)
    }

    @Test func localDocumentsKeepEmbeddedWebKitIdentity() {
        #expect(policy.customUserAgent(for: URL(string: "about:blank")!) == nil)
        #expect(policy.customUserAgent(for: URL(fileURLWithPath: "/tmp/example.html")) == nil)
    }

    @Test func googleSheetsAndNonWebDestinationsHaveDistinctPolicyOutcomes() {
        let sheetURL = URL(string: "https://docs.google.com/spreadsheets/d/example/edit")!
        let fileURL = URL(fileURLWithPath: "/tmp/example.html")

        #expect(policy.customUserAgent(for: sheetURL) != policy.customUserAgent(for: fileURL))
    }
}
