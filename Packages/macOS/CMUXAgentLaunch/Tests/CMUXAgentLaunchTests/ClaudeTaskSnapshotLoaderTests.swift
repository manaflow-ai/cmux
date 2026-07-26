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

        #expect(ClaudeTaskSnapshotLoader.tasksRootURL(
            environment: ["HOME": "/tmp/hook-home"],
            homeDirectoryURL: home
        ).path == "/tmp/hook-home/.claude/tasks")
        #expect(ClaudeTaskSnapshotLoader.tasksRootURL(
            environment: [
                "HOME": "/tmp/hook-home",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-profile",
            ],
            homeDirectoryURL: home
        ).path == "/tmp/claude-profile/tasks")
        #expect(ClaudeTaskSnapshotLoader.tasksRootURL(
            environment: [
                "HOME": "/tmp/hook-home",
                "CLAUDE_CONFIG_DIR": "~/claude-profile",
            ],
            homeDirectoryURL: home
        ).path == "/tmp/hook-home/claude-profile/tasks")
        #expect(ClaudeTaskSnapshotLoader.tasksRootURL(
            environment: ["HOME": "  "],
            homeDirectoryURL: home
        ).path == "/Users/example/.claude/tasks")
    }

    private func writeTask(_ json: String, named name: String, in directory: URL) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }
}
