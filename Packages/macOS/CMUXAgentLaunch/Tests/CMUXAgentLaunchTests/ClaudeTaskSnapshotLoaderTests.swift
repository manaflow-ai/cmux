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
        let snapshot = try #require(try loader.load(sessionID: "abc"))
        let todos = snapshot.todos

        #expect(snapshot.directoryName == "session-abc")
        #expect(todos.map(\.id) == ["2", "10"])
        #expect(todos.map(\.content) == ["Write the test", "Ship the fix"])
        #expect(todos.map(\.activeForm) == ["Writing the test", "Shipping the fix"])
        #expect(todos.map(\.state) == [.completed, .inProgress])
        #expect(todos.map(\.displayContent) == ["Write the test", "Shipping the fix"])
    }

    @Test("Ignores a task record whose filename does not match its identity")
    func ignoresMismatchedTaskFilename() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-task-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("identity", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"2","subject":"Mismatched task","status":"pending"}"#,
            named: "1.json",
            in: sessionDirectory
        )

        let snapshot = try #require(
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "identity")
        )

        #expect(snapshot.todos.isEmpty)
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

        let snapshot = try #require(
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "abc")
        )

        #expect(snapshot.directoryName == "abc")
        #expect(snapshot.todos.map(\.content) == ["First task"])
    }

    @Test("A deterministic session directory wins over duplicate neighboring identities")
    func prefersDeterministicSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-direct-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("plain-session", isDirectory: true)
        let neighboringDirectory = root.appendingPathComponent("session-team-b", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighboringDirectory, withIntermediateDirectories: true)
        for directory in [sessionDirectory, neighboringDirectory] {
            try writeTask(
                #"{"id":"1","subject":"Shared task","status":"pending"}"#,
                named: "1.json",
                in: directory
            )
        }

        let snapshot = try #require(try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(
            sessionID: "plain-session",
            taskIdentity: ClaudeTaskIdentity(id: "1", subject: "Shared task")
        ))

        #expect(snapshot.directoryName == "plain-session")
    }

    @Test("Resolves an unrelated team directory by one exact task identity")
    func resolvesUniqueTeamDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-team-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let matchingDirectory = root.appendingPathComponent("session-team-a", isDirectory: true)
        let neighboringDirectory = root.appendingPathComponent("session-team-b", isDirectory: true)
        try FileManager.default.createDirectory(at: matchingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighboringDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Team task","status":"pending"}"#,
            named: "1.json",
            in: matchingDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Neighbor task","status":"pending"}"#,
            named: "1.json",
            in: neighboringDirectory
        )

        let snapshot = try #require(try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(
            sessionID: "unrelated-hook-session",
            taskIdentity: ClaudeTaskIdentity(id: "1", subject: "Team task")
        ))

        #expect(snapshot.directoryName == "session-team-a")
        #expect(snapshot.todos.map(\.content) == ["Team task"])
    }

    @Test("Rejects an ambiguous team-directory identity")
    func rejectsAmbiguousTeamDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-ambiguous-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["session-team-a", "session-team-b"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeTask(
                #"{"id":"1","subject":"Shared task","status":"pending"}"#,
                named: "1.json",
                in: directory
            )
        }

        let snapshot = try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(
            sessionID: "unrelated-hook-session",
            taskIdentity: ClaudeTaskIdentity(id: "1", subject: "Shared task")
        )

        #expect(snapshot == nil)
    }

    @Test("A bound empty directory remains an authoritative snapshot")
    func distinguishesBoundEmptyDirectoryFromUnresolved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-empty-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let boundDirectory = root.appendingPathComponent("session-team-a", isDirectory: true)
        try FileManager.default.createDirectory(at: boundDirectory, withIntermediateDirectories: true)
        let loader = ClaudeTaskSnapshotLoader(tasksRootURL: root)

        let emptySnapshot = try #require(try loader.load(
            sessionID: "unrelated-hook-session",
            boundDirectoryName: "session-team-a"
        ))

        #expect(emptySnapshot.directoryName == "session-team-a")
        #expect(emptySnapshot.todos.isEmpty)
        #expect(try loader.load(sessionID: "unrelated-hook-session") == nil)
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

        let snapshot = try #require(
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "boundary")
        )

        #expect(snapshot.todos.count == 1)
        #expect(snapshot.todos[0].content.utf8.count == paddingCount)
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

    @Test("Team-directory resolution rejects a task root beyond the entry boundary")
    func rejectsTaskRootBeyondEntryBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-root-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0...ClaudeTaskSnapshotLoader.maximumTaskRootEntryCount {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("unrelated-\(index)", isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        #expect(throws: ClaudeTaskSnapshotLoaderError.tooManyTaskRootEntries(
            limit: ClaudeTaskSnapshotLoader.maximumTaskRootEntryCount
        )) {
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(
                sessionID: "missing-session",
                taskIdentity: ClaudeTaskIdentity(id: "1", subject: "Missing task")
            )
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
