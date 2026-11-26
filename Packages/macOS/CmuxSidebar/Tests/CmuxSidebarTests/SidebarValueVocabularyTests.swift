import Foundation
import Testing
@testable import CmuxSidebar

@Suite struct SidebarWireValueTests {
    /// Raw values arrive over the control socket; round-trips are frozen.
    @Test func metadataFormatRawValuesRoundTrip() {
        #expect(SidebarMetadataFormat(rawValue: "plain") == .plain)
        #expect(SidebarMetadataFormat(rawValue: "markdown") == .markdown)
        #expect(SidebarMetadataFormat(rawValue: "html") == nil)
    }

    @Test func logLevelRawValuesRoundTrip() {
        for (raw, level) in [("info", SidebarLogLevel.info), ("progress", .progress),
                             ("success", .success), ("warning", .warning), ("error", .error)] {
            #expect(SidebarLogLevel(rawValue: raw) == level)
            #expect(level.rawValue == raw)
        }
    }

    @Test func pullRequestStatusRawValuesRoundTrip() {
        for (raw, status) in [("open", SidebarPullRequestStatus.open), ("merged", .merged), ("closed", .closed)] {
            #expect(SidebarPullRequestStatus(rawValue: raw) == status)
            #expect(status.rawValue == raw)
        }
    }
}

@Suite struct SidebarBranchNameNormalizationTests {
    /// Parity with the legacy `normalizedSidebarBranchName(_:)` helper.
    @Test func trimsWhitespaceAndDropsEmpty() {
        #expect("  main \n".normalizedSidebarBranchName == "main")
        #expect("main".normalizedSidebarBranchName == "main")
        #expect("   ".normalizedSidebarBranchName == nil)
        #expect("".normalizedSidebarBranchName == nil)
        let none: String? = nil
        #expect(none?.normalizedSidebarBranchName == nil)
    }

    /// `SidebarPullRequestState.init` normalizes the branch like the legacy init.
    @Test func pullRequestStateNormalizesBranch() throws {
        let url = try #require(URL(string: "https://github.com/o/r/pull/1"))
        #expect(SidebarPullRequestState(number: 1, label: "o/r", url: url, status: .open, branch: " b ").branch == "b")
        #expect(SidebarPullRequestState(number: 1, label: "o/r", url: url, status: .open, branch: "  ").branch == nil)
        #expect(SidebarPullRequestState(number: 1, label: "o/r", url: url, status: .open).branch == nil)
    }
}
