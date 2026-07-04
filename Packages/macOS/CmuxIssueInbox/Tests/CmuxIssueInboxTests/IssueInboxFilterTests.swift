@testable import CmuxIssueInbox
import Foundation
import Testing

@Suite
struct IssueInboxFilterTests {
    @Test
    func filtersByStatusProviderAndSearch() {
        let openGitHub = item(
            id: "github:manaflow-ai/cmux:1",
            provider: .github,
            status: .open,
            title: "Fix terminal restore",
            number: "1",
            labels: ["bug"]
        )
        let closedGitHub = item(
            id: "github:manaflow-ai/cmux:2",
            provider: .github,
            status: .closed,
            title: "Closed item",
            number: "2",
            labels: ["done"]
        )
        let openLinear = item(
            id: "linear:ENG:ENG-3",
            provider: .linear,
            status: .open,
            title: "Build Issue Inbox",
            number: "ENG-3",
            labels: ["feature"]
        )
        let items = [openGitHub, closedGitHub, openLinear]

        #expect(IssueInboxFilter().apply(to: items) == [openGitHub, openLinear])
        #expect(IssueInboxFilter(status: .closed).apply(to: items) == [closedGitHub])
        #expect(IssueInboxFilter(status: .all, provider: .linear).apply(to: items) == [openLinear])
        #expect(IssueInboxFilter(status: .all, query: "terminal").apply(to: items) == [openGitHub])
        #expect(IssueInboxFilter(status: .all, query: "eng-3").apply(to: items) == [openLinear])
        #expect(IssueInboxFilter(status: .all, query: "FEATURE").apply(to: items) == [openLinear])
    }

    private func item(
        id: String,
        provider: IssueProviderKind,
        status: IssueStatus,
        title: String,
        number: String,
        labels: [String]
    ) -> IssueInboxItem {
        IssueInboxItem(
            id: id,
            provider: provider,
            sourceURL: URL(string: "https://example.com/\(id)")!,
            title: title,
            status: status,
            updatedAt: Date(timeIntervalSince1970: 100),
            repoOrProject: provider == .github ? "manaflow-ai/cmux" : "ENG",
            number: number,
            labels: labels
        )
    }
}
