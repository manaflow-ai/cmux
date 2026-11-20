import Foundation
import Testing
@testable import CmuxNextSidebar

/// Agent-session metadata keeps a second line only when it tells the person something new.
struct SidebarWorkspaceSubtitleTests {
    @Test func localSessionNameIsNotRepeated() {
        #expect(WorkspaceRowContent.nonRedundantDetail("local · demo-session", title: "demo-session") == nil)
    }

    @Test func remoteHostIsRetained() {
        #expect(WorkspaceRowContent.nonRedundantDetail("build-mac · demo-session", title: "demo-session") == "build-mac · demo-session")
    }

    @Test func differentWorkingDirectoryIsRetained() {
        #expect(WorkspaceRowContent.nonRedundantDetail("local · ~/work/demo", title: "demo-session") == "local · ~/work/demo")
    }

    @Test func statusIsRetained() {
        #expect(WorkspaceRowContent.nonRedundantDetail("local · Waiting", title: "demo-session") == "local · Waiting")
    }
}
