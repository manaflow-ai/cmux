import Foundation
import Testing

@testable import CmuxSidebar

@Suite struct SidebarManualPullRequestStoreTests {
    private let url = URL(string: "https://github.com/owner/repo/pull/12746")!

    @Test func attachReplaceAndClearAreIdempotent() {
        var store = SidebarManualPullRequestStore()
        #expect(store.attach(number: 12746, label: "PR", url: url, status: .open, branch: "feature/pr"))
        #expect(store.state?.number == 12746)
        #expect(!store.attach(number: 12746, label: "PR", url: url, status: .open, branch: "feature/pr"))
        #expect(store.attach(number: 12747, label: "PR", url: url, status: .merged, branch: "main"))
        #expect(store.state?.status == .merged)
        #expect(store.clear())
        #expect(store.state == nil)
        #expect(!store.clear())
    }

    @Test func reconcilePreservesManualIdentityAndUpdatesStatus() {
        var store = SidebarManualPullRequestStore()
        _ = store.attach(number: 12746, label: "owner/repo", url: url, status: .open, branch: "feature/pr")

        let watcher = SidebarPullRequestState(
            number: 12746,
            label: "watcher-label",
            url: URL(string: "HTTPS://GITHUB.COM/OWNER/REPO/PULL/12746")!,
            status: .closed,
            branch: "other",
            isStale: false
        )
        #expect(store.reconcile(with: watcher))
        #expect(store.state?.label == "owner/repo")
        #expect(store.state?.branch == "feature/pr")
        #expect(store.state?.status == .closed)
    }

    @Test(arguments: [
        SidebarPullRequestState(number: 1, label: "PR", url: URL(string: "https://github.com/owner/repo/pull/1")!, status: .open, isStale: true),
        SidebarPullRequestState(number: 2, label: "PR", url: URL(string: "https://github.com/owner/repo/pull/12746")!, status: .open),
        SidebarPullRequestState(number: 12746, label: "PR", url: URL(string: "https://github.com/other/repo/pull/12746")!, status: .open)
    ])
    func reconcileIgnoresNonMatchingWatcherState(_ watcher: SidebarPullRequestState) {
        var store = SidebarManualPullRequestStore()
        _ = store.attach(number: 12746, label: "PR", url: url, status: .open, branch: "feature/pr")
        #expect(!store.reconcile(with: watcher))
        #expect(store.state?.status == .open)
    }
}
