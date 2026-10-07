import Foundation
import Testing
@testable import CMUXAgentLaunch

struct AgentArtifactInventoryTests {
    @Test func scanIncludesOnlyMarkedRunsAndBoundsFiles() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marked = home.appendingPathComponent(".local/state/cmux/agent-artifacts/codex/run-1", isDirectory: true)
        let unmarked = home.appendingPathComponent(".local/state/cmux/agent-artifacts/codex/run-2", isDirectory: true)
        try fileManager.createDirectory(at: marked, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: unmarked, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        try Data("cmux-agent-artifact-v1\n".utf8).write(to: marked.appendingPathComponent(".cmux-owned"))
        try Data(repeating: 1, count: 4).write(to: marked.appendingPathComponent("one.log"))
        try Data(repeating: 2, count: 5).write(to: marked.appendingPathComponent("two.log"))
        try Data("not owned\n".utf8).write(to: unmarked.appendingPathComponent("secret.txt"))

        let report = AgentArtifactInventory.scan(
            homeDirectory: home,
            fileManager: fileManager,
            limits: .init(maximumRuns: 10, maximumFilesPerRun: 1, maximumBytesPerRun: 100)
        )

        #expect(report.entries.map(\.sessionID) == ["run-1"])
        #expect(report.entries[0].fileCount == 1)
        #expect(report.entries[0].bytes == 4)
        #expect(report.entries[0].scanTruncated)
        #expect(report.totalBytes == 4)
    }

    @Test func scanRejectsMarkerAndArtifactSymlinks() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent(".local/state/cmux/agent-artifacts/claude/run-1", isDirectory: true)
        let outside = home.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        try Data("cmux-agent-artifact-v1\n".utf8).write(to: outside.appendingPathComponent(".cmux-owned"))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent(".cmux-owned"), withDestinationURL: outside.appendingPathComponent(".cmux-owned"))
        try Data("secret\n".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("linked.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))

        #expect(AgentArtifactInventory.scan(homeDirectory: home, fileManager: fileManager).entries.isEmpty)
        #expect(AgentArtifactInventory.inspect(provider: "..", sessionID: "escape", homeDirectory: home, fileManager: fileManager) == nil)
    }

    @Test func scanRejectsCanonicalRootEscapingHomeThroughAncestorSymlink() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outsideRun = outside.appendingPathComponent(".local/state/cmux/agent-artifacts/codex/run-1", isDirectory: true)
        try fileManager.createDirectory(at: outsideRun, withIntermediateDirectories: true)
        try Data("cmux-agent-artifact-v1\n".utf8).write(to: outsideRun.appendingPathComponent(".cmux-owned"))
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: home.appendingPathComponent(".local"),
            withDestinationURL: outside.appendingPathComponent(".local")
        )
        defer {
            try? fileManager.removeItem(at: home)
            try? fileManager.removeItem(at: outside)
        }

        #expect(AgentArtifactInventory.scan(homeDirectory: home, fileManager: fileManager).entries.isEmpty)
    }

    @Test func scanBoundsDirectoryOnlyTraversal() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent(".local/state/cmux/agent-artifacts/codex/run-1", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        try Data("cmux-agent-artifact-v1\n".utf8).write(to: root.appendingPathComponent(".cmux-owned"))
        for index in 0..<10 {
            try fileManager.createDirectory(
                at: root.appendingPathComponent("nested-\(index)/child", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let report = AgentArtifactInventory.scan(
            homeDirectory: home,
            fileManager: fileManager,
            limits: .init(maximumVisitedEntriesPerRun: 3)
        )

        #expect(report.entries.count == 1)
        #expect(report.entries[0].scanTruncated)
        #expect(report.entries[0].fileCount == 0)
    }
}
