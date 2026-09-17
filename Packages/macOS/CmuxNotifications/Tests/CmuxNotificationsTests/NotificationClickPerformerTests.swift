import Foundation
import Testing
@testable import CmuxNotifications

/// Scriptable Finder seam: a set of existing paths plus a log of every
/// select/open call, so the file-vs-directory fallback and the exact path passed
/// to `NSWorkspace` can be asserted.
@MainActor
private final class FakeFinder: FinderRevealing {
    var existingPaths: Set<String> = []
    var selectSucceeds = true
    var openSucceeds = true
    private(set) var selected: [String] = []
    private(set) var opened: [String] = []

    func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }

    func selectFileInFinder(path: String) -> Bool {
        selected.append(path)
        return selectSucceeds
    }

    func openDirectoryInFinder(path: String) -> Bool {
        opened.append(path)
        return openSucceeds
    }
}

@Suite(.serialized)
@MainActor
struct NotificationClickPerformerTests {
    @Test("reveal selects the file when it exists")
    func selectsExistingFile() {
        let finder = FakeFinder()
        finder.existingPaths = ["/tmp/cmux/report.txt"]
        let performer = NotificationClickPerformer(finder: finder)

        #expect(performer.perform(.revealInFinder(path: "/tmp/cmux/report.txt")))
        #expect(finder.selected == ["/tmp/cmux/report.txt"])
        #expect(finder.opened.isEmpty)
    }

    @Test("reveal opens the containing directory when the file is missing")
    func opensContainingDirectory() {
        let finder = FakeFinder()
        // File missing, parent dir exists → open the directory.
        finder.existingPaths = ["/tmp/cmux"]
        let performer = NotificationClickPerformer(finder: finder)

        #expect(performer.perform(.revealInFinder(path: "/tmp/cmux/missing.txt")))
        #expect(finder.selected.isEmpty)
        #expect(finder.opened == ["/tmp/cmux"])
    }

    @Test("reveal fails when neither the file nor its directory exists")
    func failsWhenNothingExists() {
        let finder = FakeFinder()
        let performer = NotificationClickPerformer(finder: finder)

        #expect(performer.perform(.revealInFinder(path: "/tmp/cmux/missing.txt")) == false)
        #expect(finder.selected.isEmpty)
        #expect(finder.opened.isEmpty)
    }

    @Test("reveal fails on an empty path without touching the seam")
    func failsOnEmptyPath() {
        let finder = FakeFinder()
        let performer = NotificationClickPerformer(finder: finder)

        #expect(performer.perform(.revealInFinder(path: "   ")) == false)
        #expect(finder.selected.isEmpty)
        #expect(finder.opened.isEmpty)
    }

    @Test("reveal expands a leading tilde before checking existence")
    func expandsTilde() {
        let finder = FakeFinder()
        let expandedHome = ("~" as NSString).expandingTildeInPath
        let expectedPath = expandedHome + "/cmux-file.txt"
        finder.existingPaths = [expectedPath]
        let performer = NotificationClickPerformer(finder: finder)

        #expect(performer.perform(.revealInFinder(path: "~/cmux-file.txt")))
        #expect(finder.selected == [expectedPath])
    }

    @Test("reveal propagates the directory-open result")
    func propagatesOpenFailure() {
        let finder = FakeFinder()
        finder.existingPaths = ["/tmp/cmux"]
        finder.openSucceeds = false
        let performer = NotificationClickPerformer(finder: finder)

        #expect(performer.perform(.revealInFinder(path: "/tmp/cmux/missing.txt")) == false)
        #expect(finder.opened == ["/tmp/cmux"])
    }
}
