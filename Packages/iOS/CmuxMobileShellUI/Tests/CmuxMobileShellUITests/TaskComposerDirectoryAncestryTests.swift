#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerDirectoryAncestryTests {
    @Test func absolutePathSeedsEveryAncestorRootFirst() {
        #expect(
            TaskComposerDirectoryAncestry.chain(for: "/Users/ui/mobile-root")
                == ["/", "/Users", "/Users/ui", "/Users/ui/mobile-root"]
        )
    }

    @Test func filesystemRootIsASingleLevel() {
        #expect(TaskComposerDirectoryAncestry.chain(for: "/") == ["/"])
    }

    @Test func homeShorthandStaysUnexpanded() {
        #expect(TaskComposerDirectoryAncestry.chain(for: "~") == ["~"])
    }

    @Test func homeRelativePathSeedsFromHome() {
        #expect(
            TaskComposerDirectoryAncestry.chain(for: "~/Dev/app")
                == ["~", "~/Dev", "~/Dev/app"]
        )
    }

    @Test func trailingAndRepeatedSlashesCollapse() {
        #expect(
            TaskComposerDirectoryAncestry.chain(for: "/Users//ui/")
                == ["/", "/Users", "/Users/ui"]
        )
    }

    @Test func emptySelectionFallsBackToHome() {
        #expect(TaskComposerDirectoryAncestry.chain(for: "  ") == ["~"])
    }

    @Test func opaqueRelativePathBrowsesAsOneScreen() {
        #expect(TaskComposerDirectoryAncestry.chain(for: "Dev/app") == ["Dev/app"])
    }

    @Test func deepPathsKeepTheDeepestLevels() {
        let components = (1...20).map { "level\($0)" }
        let path = "/" + components.joined(separator: "/")
        let chain = TaskComposerDirectoryAncestry.chain(for: path)

        #expect(chain.count == TaskComposerDirectoryAncestry.maxSeededDepth)
        #expect(chain.last == path)
        #expect(chain.first == "/" + components.prefix(9).joined(separator: "/"))
    }
}
#endif
