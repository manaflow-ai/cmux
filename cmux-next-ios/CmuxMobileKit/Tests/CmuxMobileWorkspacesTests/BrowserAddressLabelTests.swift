import Foundation
import Testing
@testable import CmuxMobileWorkspaces

// WorkspaceTabsSource is iOS-only: this runs in the iOS simulator test pass.
#if os(iOS)
import CmuxTabsKit

/// A long browser address never reaches the toolbar or the tab grid raw
/// (the reconnecting tab's collapsed pill showed a whole file: path).
@MainActor struct BrowserAddressLabelTests {
    let file = URL(string: "file:///Users/azizalbahar/Development/cmuxterm-hq/worktrees/feat-cnx-ios/cnx-ios/verify/iphone-link-sequence.html")!

    @Test func fileTabShowsFileNameAndTitle() {
        let label = TabsKitAddress.displayLabel(for: file)
        #expect(label == "iphone-link-sequence.html")
        // A file page without a <title> reports its URL or path as the title.
        #expect(WorkspaceTabsSource.browserTitle(file.absoluteString, fallback: "Browser", url: file, label: label) == label)
        #expect(WorkspaceTabsSource.browserTitle(file.path, fallback: "Browser", url: file, label: label) == label)
        #expect(WorkspaceTabsSource.browserTitle(nil, fallback: "", url: file, label: label) == label)
        // A decoded URL as the title (a name with a space) is still the URL.
        let spaced = URL(string: "file:///tmp/a%20b/long%20name.html")!
        #expect(WorkspaceTabsSource.browserTitle("file:///tmp/a b/long name.html", fallback: "", url: spaced, label: "long name.html") == "long name.html")
    }

    @Test func realTitlesStay() {
        let url = URL(string: "https://www.example.com/a/b")!
        #expect(WorkspaceTabsSource.browserTitle("Example Domain", fallback: "Browser", url: url, label: "example.com") == "Example Domain")
        #expect(WorkspaceTabsSource.browserTitle("", fallback: "Browser", url: url, label: "example.com") == "Browser")
    }
}
#endif
