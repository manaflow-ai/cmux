import CoreServices
import Foundation
import Testing
@testable import CmuxNextFiles

/// FSEvents' root watch opens the folder in the app's process, which macOS charges to the app for
/// ~/Downloads. A build that reads folders in another process watches without it, and still learns
/// of its children's changes and of the folder's own removal (docs/cmux-files-host.md).
struct FolderWatchRootTests {
    @Test func theRootWatchIsLeftOutOnlyWhenAsked() {
        let root = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        #expect(FolderWatchStream.flags(watchingRoot: true) & root != 0)
        #expect(FolderWatchStream.flags(watchingRoot: false) & root == 0)
        #expect(FolderWatchStream.flags(watchingRoot: false) & FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents) != 0)
    }

    @Test func withoutTheRootWatchTheFoldersOwnRemovalRescans() async {
        let (changes, continuation) = AsyncStream<FolderChange>.makeStream()
        let stream = FolderWatchStream(folder: URL(fileURLWithPath: "/tmp/watched"), latency: 0.05,
                                       watchesRoot: { false }, continuation: continuation)
        stream.watchingRoot = false
        stream.deliver(paths: ["/tmp/watched"], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)])
        stream.deliver(paths: ["/tmp/watched/a.txt"], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)])
        continuation.finish()
        var seen: [FolderChange] = []
        for await change in changes { seen.append(change) }
        #expect(seen == [.rescan, .items(["a.txt"])])
    }

    @Test func aWatchWithoutTheRootStillSeesNewChildren() async throws {
        let temp = try TempFolder()
        let changes = FolderWatcher(watchesRoot: { false }).changes(in: temp.url)
        try await Task.sleep(for: .milliseconds(300))
        try temp.file("new.txt")
        let seen = await withTaskGroup(of: [String].self) { group in
            group.addTask {
                for await change in changes { if case .items(let names) = change, names.contains("new.txt") { return names } }
                return []
            }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return [] }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
        #expect(seen.contains("new.txt"))
    }
}
