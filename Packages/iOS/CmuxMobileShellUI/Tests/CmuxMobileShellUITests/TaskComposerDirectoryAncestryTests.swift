#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerDirectoryAncestryTests {
    private func paths(for selection: String) -> [String] {
        TaskComposerDirectoryBrowseDestination.ancestry(for: selection).map(\.path)
    }

    @Test func absolutePathSeedsEveryAncestorRootFirst() {
        #expect(
            paths(for: "/Users/ui/mobile-root")
                == ["/", "/Users", "/Users/ui", "/Users/ui/mobile-root"]
        )
    }

    @Test func filesystemRootIsASingleLevel() {
        #expect(paths(for: "/") == ["/"])
    }

    @Test func homeShorthandStaysUnexpanded() {
        #expect(paths(for: "~") == ["~"])
    }

    @Test func homeRelativePathSeedsFromHome() {
        #expect(paths(for: "~/Dev/app") == ["~", "~/Dev", "~/Dev/app"])
    }

    @Test func trailingAndRepeatedSlashesCollapse() {
        #expect(paths(for: "/Users//ui/") == ["/", "/Users", "/Users/ui"])
    }

    @Test func emptySelectionFallsBackToHome() {
        #expect(paths(for: "  ") == ["~"])
    }

    @Test func opaqueRelativePathBrowsesAsOneScreen() {
        #expect(paths(for: "Dev/app") == ["Dev/app"])
    }

    @Test func deepPathsKeepTheDeepestLevels() {
        let components = (1...20).map { "level\($0)" }
        let path = "/" + components.joined(separator: "/")
        let chain = paths(for: path)

        #expect(chain.count == TaskComposerDirectoryBrowseDestination.maxSeededDepth)
        #expect(chain.last == path)
        #expect(chain.first == "/" + components.prefix(9).joined(separator: "/"))
    }
}
#endif
