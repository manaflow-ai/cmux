import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Claude task snapshots")
struct ClaudeTaskSnapshotLoaderTests {
    @Test("Loads a complete session snapshot and omits deleted tasks")
    func loadsCompleteSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-tasks-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = root.appendingPathComponent("session-abc", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeTask(
            #"{"id":"10","subject":"Ship the fix","activeForm":"Shipping the fix","status":"in_progress"}"#,
            named: "10.json",
            in: sessionDirectory
        )
        try writeTask(
            #"{"id":"2","subject":"Write the test","activeForm":"Writing the test","status":"completed"}"#,
            named: "2.json",
            in: sessionDirectory
        )
        try writeTask(
            #"{"id":"3","subject":"Old task","activeForm":"Deleting the old task","status":"deleted"}"#,
            named: "3.json",
            in: sessionDirectory
        )
        try writeTask(#"{"broken":true}"#, named: "malformed.json", in: sessionDirectory)

        let loader = ClaudeTaskSnapshotLoader(tasksRootURL: root)
        let todos = try loader.load(sessionID: "abc")

        #expect(todos.map(\.id) == ["2", "10"])
        #expect(todos.map(\.content) == ["Write the test", "Ship the fix"])
        #expect(todos.map(\.activeForm) == ["Writing the test", "Shipping the fix"])
        #expect(todos.map(\.state) == [.completed, .inProgress])
        #expect(todos.map(\.displayContent) == ["Write the test", "Shipping the fix"])
    }

    @Test("Supports the unprefixed session directory layout")
    func supportsUnprefixedSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-tasks-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = root.appendingPathComponent("abc", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTask(
            #"{"id":"1","subject":"First task","status":"pending"}"#,
            named: "1.json",
            in: sessionDirectory
        )

        let todos = try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "abc")

        #expect(todos.map(\.content) == ["First task"])
    }

    @Test("Resolves the task root from Claude's configured directory")
    func resolvesConfiguredTaskRoot() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        #expect(ClaudeTaskRootResolver(
            environment: ["HOME": "/tmp/hook-home"],
            homeDirectoryURL: home
        ).resolve().path == "/tmp/hook-home/.claude/tasks")
        #expect(ClaudeTaskRootResolver(
            environment: [
                "HOME": "/tmp/hook-home",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-profile",
            ],
            homeDirectoryURL: home
        ).resolve().path == "/tmp/claude-profile/tasks")
        #expect(ClaudeTaskRootResolver(
            environment: [
                "HOME": "/tmp/hook-home",
                "CLAUDE_CONFIG_DIR": "~/claude-profile",
            ],
            homeDirectoryURL: home
        ).resolve().path == "/tmp/hook-home/claude-profile/tasks")
        #expect(ClaudeTaskRootResolver(
            environment: ["HOME": "  "],
            homeDirectoryURL: home
        ).resolve().path == "/Users/example/.claude/tasks")
    }

    @Test("Task snapshots accept the entry and file-size boundaries")
    func acceptsResourceBoundaries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("boundary", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let prefix = "{\"id\":\"1\",\"subject\":\""
        let suffix = "\",\"status\":\"pending\"}"
        let paddingCount = ClaudeTaskSnapshotLoader.maximumTaskFileByteCount
            - prefix.utf8.count
            - suffix.utf8.count
        let boundaryJSON = prefix + String(repeating: "x", count: paddingCount) + suffix
        try Data(boundaryJSON.utf8).write(to: sessionDirectory.appendingPathComponent("1.json"))
        for index in 2...ClaudeTaskSnapshotLoader.maximumDirectoryEntryCount {
            try Data().write(to: sessionDirectory.appendingPathComponent("\(index).txt"))
        }

        let todos = try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "boundary")

        #expect(todos.count == 1)
        #expect(todos[0].content.utf8.count == paddingCount)
    }

    @Test("Task snapshots reject a directory beyond the entry boundary")
    func rejectsDirectoryBeyondEntryBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-entry-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("entry-overflow", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        for index in 0...ClaudeTaskSnapshotLoader.maximumDirectoryEntryCount {
            try Data().write(to: sessionDirectory.appendingPathComponent("\(index).txt"))
        }

        #expect(throws: ClaudeTaskSnapshotLoaderError.tooManyDirectoryEntries(
            limit: ClaudeTaskSnapshotLoader.maximumDirectoryEntryCount
        )) {
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "entry-overflow")
        }
    }

    @Test("Task snapshots reject a task file beyond the byte boundary")
    func rejectsTaskFileBeyondByteBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-file-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("file-overflow", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileName = "1.json"
        try Data(repeating: 0x20, count: ClaudeTaskSnapshotLoader.maximumTaskFileByteCount + 1)
            .write(to: sessionDirectory.appendingPathComponent(fileName))

        #expect(throws: ClaudeTaskSnapshotLoaderError.taskFileTooLarge(
            fileName: fileName,
            limit: ClaudeTaskSnapshotLoader.maximumTaskFileByteCount
        )) {
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "file-overflow")
        }
    }

    private func writeTask(_ json: String, named name: String, in directory: URL) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }
}
