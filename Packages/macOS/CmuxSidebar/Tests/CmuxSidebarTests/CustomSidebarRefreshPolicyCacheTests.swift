import Foundation
import Testing
@testable import CmuxSidebar

@Suite("CustomSidebarRefreshPolicyCache")
struct CustomSidebarRefreshPolicyCacheTests {
    private final class Directory {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("CustomSidebarRefreshPolicyCacheTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ name: String, _ text: String, modified: Date) throws -> URL {
            let file = url.appendingPathComponent(name)
            try text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            return file
        }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func sourceOverrideDecidesWithoutTouchingFiles() {
        let cache = CustomSidebarRefreshPolicyCache(readSource: { _ in
            Issue.record("override must not read files")
            return nil
        })
        let url = URL(fileURLWithPath: "/nonexistent/preview.js")
        #expect(cache.policy(fileURL: url, sourceOverride: "Text(clock.time)") == .everySecond)
        #expect(cache.policy(fileURL: url, sourceOverride: "Text(\"hi\")") == .onDataChange)
    }

    @Test func editAddingClockSwitchesAfterTheRecheckInterval() throws {
        let directory = try Directory()
        let file = try directory.write("side.js", "Text(() => data.selectedTitle())", modified: start)
        let cache = CustomSidebarRefreshPolicyCache()
        #expect(cache.policy(fileURL: file, now: start) == .onDataChange)

        _ = try directory.write("side.js", "Text(() => data.clock()?.time)", modified: start.addingTimeInterval(10))
        // Within the recheck interval the cached answer stands.
        #expect(cache.policy(fileURL: file, now: start.addingTimeInterval(1)) == .onDataChange)
        let later = start.addingTimeInterval(CustomSidebarRefreshPolicyCache.recheckInterval + 1)
        #expect(cache.policy(fileURL: file, now: later) == .everySecond)
    }

    @Test func siblingFileWithTheSameNameCounts() throws {
        let directory = try Directory()
        let js = try directory.write("side.js", "Text(\"a\")", modified: start)
        _ = try directory.write("side.swift", "Text(clock.time)", modified: start)
        let cache = CustomSidebarRefreshPolicyCache()
        #expect(cache.policy(fileURL: js, now: start) == .everySecond)
    }

    @Test func unchangedFilesAreNotReadAgain() throws {
        let directory = try Directory()
        let file = try directory.write("side.js", "Text(\"a\")", modified: start)
        var reads = 0
        let cache = CustomSidebarRefreshPolicyCache(readSource: { url in
            reads += 1
            return try? String(contentsOf: url, encoding: .utf8)
        })
        _ = cache.policy(fileURL: file, now: start)
        _ = cache.policy(fileURL: file, now: start.addingTimeInterval(10))
        #expect(reads == 1)
    }

    /// Editing a symlinked sidebar's target (dotfiles) must be noticed even
    /// though the link itself doesn't change.
    @Test func editingASymlinkTargetIsNoticed() throws {
        let directory = try Directory()
        let target = try directory.write("target.js", "Text(\"a\")", modified: start)
        let link = directory.url.appendingPathComponent("side.js")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let cache = CustomSidebarRefreshPolicyCache()
        #expect(cache.policy(fileURL: link, now: start) == .onDataChange)

        _ = try directory.write("target.js", "Text(clock.time)", modified: start.addingTimeInterval(10))
        let later = start.addingTimeInterval(CustomSidebarRefreshPolicyCache.recheckInterval + 1)
        #expect(cache.policy(fileURL: link, now: later) == .everySecond)
    }

    /// An existing file that can't be read must not freeze a clock sidebar:
    /// tick, and read again on the next lookup.
    @Test func unreadableFileTicksAndIsRetried() throws {
        let directory = try Directory()
        let file = try directory.write("side.js", "Text(() => data.clock()?.time)", modified: start)
        var failRead = true
        let cache = CustomSidebarRefreshPolicyCache(readSource: { url in
            failRead ? nil : try? String(contentsOf: url, encoding: .utf8)
        })
        #expect(cache.policy(fileURL: file, now: start) == .everySecond)

        _ = try directory.write("side.js", "Text(\"no time\")", modified: start)
        failRead = false
        #expect(cache.policy(fileURL: file, now: start.addingTimeInterval(0.5)) == .onDataChange)
    }
}
