import Foundation
import Testing
@testable import CmuxNextFiles

/// A DEV build lists folders in a child process (cmux-tui `__files-lister` under cmux Files
/// (dev)), so macOS asks about Downloads once for every DEV build: the lister uses the child's
/// answers, never the disk, while the child answers, and reads in process as before when it
/// cannot (docs/cmux-files-host.md, "The Files pane").
struct ProcessDirectoryListerTests {
    /// A child that answers each request line with the next of `replies`, then reads to the end.
    private func child(_ temp: TempFolder, replies: [String], name: String = "lister.sh") throws -> ProcessDirectoryLister {
        let replyFile = try temp.file("\(name).replies")
        try (replies.joined(separator: "\n") + "\n").write(to: replyFile, atomically: true, encoding: .utf8)
        let script = temp.url.appendingPathComponent(name)
        try """
        #!/bin/sh
        exec 3<"\(replyFile.path)"
        while IFS= read -r line; do IFS= read -r reply <&3 || exit 0; printf '%s\\n' "$reply"; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return ProcessDirectoryLister(arguments: [script.path])
    }

    @Test func aFolderIsListedByTheChildNotTheDisk() async throws {
        let temp = try TempFolder()
        // Not on disk: only the child can produce these entries.
        let folder = temp.url.appendingPathComponent("Downloads-not-on-disk", isDirectory: true)
        let lister = DirectoryLister(outOfProcess: try child(temp, replies: [
            #"{"id":1,"entries":[{"n":"a.txt","k":"file","s":5,"m":1700000000.5,"c":1600000000,"h":false},"#
                + #"{"n":"Thing.app","k":"dir","s":0,"m":1,"c":1,"h":false},{"n":"sub","k":"dir","s":0,"m":1,"c":1,"h":false},"#
                + #"{"n":".hidden","k":"file","s":0,"m":1,"c":1,"h":true},{"n":"ln","k":"link","s":0,"m":1,"c":1,"h":false}]}"#,
        ]))
        let entries = try await lister.list(folder)
        #expect(entries.map(\.name) == ["a.txt", "Thing.app", "sub", ".hidden", "ln"])
        #expect(entries.map(\.kind) == [.file, .package, .folder, .file, .symlink])
        #expect(entries[0].size == 5)
        #expect(entries[0].modified == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(entries[0].created == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(entries[3].isHidden)
        #expect(entries.allSatisfy { $0.parent == folder })
    }

    @Test func aFolderTheChildCannotReadIsUnreadable() async throws {
        let temp = try TempFolder()
        let lister = DirectoryLister(outOfProcess: try child(temp, replies: [#"{"id":1,"errno":1}"#]))
        await #expect(throws: FileBrowserError.unreadable(temp.url, 1)) { try await lister.list(temp.url) }
    }

    @Test func oneItemComesFromTheChildAndAGoneItemIsNil() async throws {
        let temp = try TempFolder()
        let present = try temp.file("present.txt", bytes: 3)
        let lister = DirectoryLister(outOfProcess: try child(temp, replies: [
            #"{"id":1,"entry":{"n":"other.txt","k":"file","s":42,"m":1,"c":1,"h":false}}"#,
            #"{"id":2,"entry":null}"#,
        ]))
        #expect(await lister.entry(at: present)?.size == 42)
        // The file is on disk, but the child says it is gone: its answer wins.
        #expect(await lister.entry(at: present) == nil)
    }

    @Test func aChildThatCannotAnswerFallsBackToTheDisk() async throws {
        let temp = try TempFolder()
        try temp.file("on-disk.txt")
        for lister in [ProcessDirectoryLister(arguments: ["/usr/bin/false"]),
                       ProcessDirectoryLister(arguments: [temp.url.appendingPathComponent("missing").path]),
                       try child(temp, replies: [#"{"id":1,"error":"unknown op list"}"#], name: "old.sh")] {
            let entries = try await DirectoryLister(outOfProcess: lister).list(temp.url)
            #expect(entries.map(\.name).contains("on-disk.txt"))
        }
    }

    @Test func repliesMatchTheirRequestsInOrder() async throws {
        let temp = try TempFolder()
        let lister = DirectoryLister(outOfProcess: try child(temp, replies: (1...20).map {
            #"{"id":\#($0),"entries":[{"n":"item-\#($0)","k":"file","s":\#($0),"m":1,"c":1,"h":false}]}"#
        }))
        for index in 1...20 {
            let entries = try await lister.list(temp.url.appendingPathComponent("f\(index)"))
            #expect(entries.map(\.name) == ["item-\(index)"])
        }
    }

    @Test func aBuildWithoutTheHelperReadsInProcess() async throws {
        // The test runner is not a DEV app that embeds cmux Files (dev): no child, the disk answers.
        let temp = try TempFolder()
        try temp.file("here.txt")
        let lister = ProcessDirectoryLister.forThisBuild()
        #expect(try await lister.list(temp.url) == nil)
        #expect(try await DirectoryLister(outOfProcess: lister).list(temp.url).map(\.name) == ["here.txt"])
    }

    @Test func theChildIsResolvedOnceAtTheFirstRequestNotWhenMade() async throws {
        let temp = try TempFolder()
        let asked = Counter()
        let lister = ProcessDirectoryLister(resolving: { asked.increment(); return nil })
        #expect(asked.value == 0)
        _ = try await lister.list(temp.url)
        _ = try await lister.list(temp.url)
        #expect(asked.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
