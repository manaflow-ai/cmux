import Foundation
import Testing
@testable import CmuxAgentChat

@Suite struct MarkdownRemoteImageApprovalsTests {
    private func schemeRequest(for remote: String) throws -> URL {
        var components = URLComponents()
        components.scheme = MarkdownWebViewerScheme.remoteImage.rawValue
        components.host = "image"
        components.queryItems = [URLQueryItem(name: "url", value: remote)]
        return try #require(components.url)
    }

    @Test func unapprovedSchemeRequestsAreRefusedEvenWhenTheURLIsSafe() throws {
        let approvals = MarkdownRemoteImageApprovals()
        let request = try schemeRequest(for: "https://example.com/a.png")
        #expect(MarkdownRemoteImageSecurity().remoteImageURL(from: request) != nil)
        #expect(approvals.approvedRemoteImageURL(for: request) == nil)
    }

    @Test func approvalCoversExactlyTheApprovedURL() throws {
        var approvals = MarkdownRemoteImageApprovals()
        #expect(approvals.approve("https://example.com/a.png") != nil)

        #expect(approvals.approvedRemoteImageURL(for: try schemeRequest(for: "https://example.com/a.png"))
            == URL(string: "https://example.com/a.png"))
        #expect(approvals.approvedRemoteImageURL(for: try schemeRequest(for: "https://example.com/a.png?x=1")) == nil)
        #expect(approvals.approvedRemoteImageURL(for: try schemeRequest(for: "https://example.com/b.png")) == nil)
        #expect(approvals.approvedRemoteImageURL(for: try schemeRequest(for: "https://evil.example/a.png")) == nil)
    }

    @Test func unsafeURLsCannotBeApproved() {
        var approvals = MarkdownRemoteImageApprovals()
        #expect(approvals.approve("http://example.com/a.png") == nil)
        #expect(approvals.approve("https://user:pw@example.com/a.png") == nil)
        #expect(approvals.approve("https://127.0.0.1/a.png") == nil)
        #expect(approvals.approve("https://localhost/a.png") == nil)
        #expect(approvals.approve("https://example.com:8443/a.png") == nil)
        #expect(approvals.approve("javascript:alert(1)") == nil)
    }

    @Test func revokeAllClearsApprovals() throws {
        var approvals = MarkdownRemoteImageApprovals()
        approvals.approve("https://example.com/a.png")
        approvals.revokeAll()
        #expect(approvals.approvedRemoteImageURL(for: try schemeRequest(for: "https://example.com/a.png")) == nil)
    }

    @Test func openableRemoteImageURLsArePlainWebURLs() {
        #expect(MarkdownRemoteImageApprovals.openableRemoteImageURL("https://example.com/a.png") != nil)
        #expect(MarkdownRemoteImageApprovals.openableRemoteImageURL("http://example.com/a.png") != nil)
        #expect(MarkdownRemoteImageApprovals.openableRemoteImageURL("javascript:alert(1)") == nil)
        #expect(MarkdownRemoteImageApprovals.openableRemoteImageURL("file:///etc/passwd") == nil)
        #expect(MarkdownRemoteImageApprovals.openableRemoteImageURL("https://user:pw@example.com/") == nil)
        #expect(MarkdownRemoteImageApprovals.openableRemoteImageURL("cmux-remote-image://image?url=x") == nil)
    }
}
