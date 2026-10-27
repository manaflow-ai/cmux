import Foundation
import Testing
@testable import CmuxNextFiles

/// Go to Folder parsing, Finder names, the drop rule, type-select and the live FSEvents watch.
struct FileHelpersTests {
    private let home = URL(fileURLWithPath: "/Users/me")
    private let here = URL(fileURLWithPath: "/Users/me/work")

    @Test(arguments: [
        ("~", "/Users/me"), ("~/Desktop", "/Users/me/Desktop"), ("/tmp/x", "/tmp/x"), ("sub/dir", "/Users/me/work/sub/dir"),
        ("'/a b/c'", "/a b/c"), ("/a\\ b/c", "/a b/c"), ("file:///etc/hosts", "/etc/hosts"), ("..", "/Users/me"),
    ])
    func goToFolderParsesPaths(text: String, path: String) {
        let resolver = GoToFolderResolver(home: home, fileExists: { _ in (true, true) })
        #expect(resolver.url(for: text, relativeTo: here)?.path == path)
    }

    @Test func goToAFileSelectsItInItsFolder() {
        let resolver = GoToFolderResolver(home: home, fileExists: { path in (true, !path.hasSuffix(".md")) })
        let destination = resolver.resolve("~/notes/a.md", relativeTo: here)
        #expect(destination?.folder.path == "/Users/me/notes")
        #expect(destination?.select?.lastPathComponent == "a.md")
        #expect(GoToFolderResolver(home: home, fileExists: { _ in (false, false) }).resolve("/nope", relativeTo: here) == nil)
    }

    @Test func completionsMatchTheLastPartAndSkipDotNames() {
        let resolver = GoToFolderResolver(home: home)
        #expect(resolver.completions(for: "~/Do", names: ["Downloads", "Documents", "Desktop", ".dotfile"]) == ["Documents", "Downloads"])
        #expect(resolver.completions(for: "~/.d", names: ["Downloads", ".dotfile"]) == [".dotfile"])
    }

    @Test func finderNames() {
        let namer = FileNamer()
        #expect(namer.freeName(for: "a.txt", style: .copy, taken: ["a.txt"]) == "a copy.txt")
        #expect(namer.freeName(for: "a.txt", style: .copy, taken: ["a.txt", "a copy.txt"]) == "a copy 2.txt")
        #expect(namer.freeName(for: "folder", style: .number, taken: ["folder", "folder 2"]) == "folder 3")
        #expect(namer.freeName(for: "new", style: .number, taken: []) == "new")
        #expect(FileNamer(copyWord: "Kopie").freeName(for: "x", style: .copy, taken: []) == "x Kopie")
        #expect(!namer.isValid("a/b") && !namer.isValid("..") && !namer.isValid("") && namer.isValid(".env"))
    }

    @Test func dropMovesOnOneVolumeCopiesAcrossAndModifiersWin() {
        let policy = DropPolicy(volumeOf: { $0.path.hasPrefix("/Volumes/USB") ? 2 : 1 })
        let local = [URL(fileURLWithPath: "/Users/me/a")]
        let usb = URL(fileURLWithPath: "/Volumes/USB/dest")
        #expect(policy.mode(for: local, into: here, option: false, command: false) == .move)
        #expect(policy.mode(for: local, into: usb, option: false, command: false) == .copy)
        #expect(policy.mode(for: local, into: here, option: true, command: false) == .copy)
        #expect(policy.mode(for: local, into: usb, option: false, command: true) == .move)
    }

    @Test func typeSelectTimesOut() {
        var buffer = TypeSelectBuffer(timeout: 1)
        let start = Date(timeIntervalSince1970: 0)
        #expect(buffer.type("a", at: start) == "a")
        #expect(buffer.type("b", at: start + 0.5) == "ab")
        #expect(buffer.type("c", at: start + 2) == "c")
    }

    @Test(.timeLimit(.minutes(1)))
    func fsEventsReportCreatedChildren() async throws {
        let temp = try TempFolder()
        let stream = FolderWatcher(latency: 0.01).changes(in: temp.url)
        // FSEvents needs its stream scheduled before the change; keep writing
        // until a change for the file arrives (bounded by the test's time limit).
        let writer = Task {
            var n = 0
            while !Task.isCancelled {
                _ = try? temp.file("made-\(n)")
                n += 1
                // A bounded, cancelled pause between writes (the real signal is the stream below).
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { writer.cancel() }
        for await change in stream {
            if case .items(let names) = change, names.contains(where: { $0.hasPrefix("made-") }) { return }
            if change == .rescan { return }
        }
        Issue.record("the stream ended without a change")
    }

    #if canImport(Darwin)
    /// A folder under /private (the temp directory, the macOS screenshot preview folder) reports
    /// its children by name: FSEvents gives /private/var/... paths, so the watch must compare
    /// against the real path, not `resolvingSymlinksInPath()`'s /var/... form.
    @Test(.timeLimit(.minutes(1)))
    func aFolderUnderPrivateReportsItsChildrenByName() async throws {
        let temp = try TempFolder()
        let real = URL(fileURLWithPath: "/private" + temp.url.path, isDirectory: true)
        try #require(temp.url.path.hasPrefix("/var/"), "the temp folder sits under /var -> /private/var")
        let stream = FolderWatcher(latency: 0.01).changes(in: real)
        let writer = Task {
            var n = 0
            while !Task.isCancelled {
                _ = try? temp.file("private-\(n)")
                n += 1
                // A bounded, cancelled pause between writes (the real signal is the stream below).
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { writer.cancel() }
        for await change in stream {
            if case .items(let names) = change, names.contains(where: { $0.hasPrefix("private-") }) { return }
        }
        Issue.record("the stream ended without a named change")
    }
    #endif
}
