import Foundation
import Testing
@testable import CmuxGit

@Suite("Worktree include bounded arguments")
struct WorktreeIncludeBoundedArgumentTests {
    @Test("many collapsed directories use one exclusion file")
    func collapsedDirectoriesDoNotExpandArguments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktree-include-argv-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let runner = CandidateFilteringCommandRunner(collapsedDirectoryCount: 300)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for index in 0..<300 {
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent("node_modules/pkg-\(index)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try "node_modules/\n.env\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "secret=value\n".write(
            to: source.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService(commandRunner: runner).sync(
            from: source,
            to: destination
        )
        let invocations = await runner.invocations()
        let includeFileInvocation = try #require(invocations.first { invocation in
            !invocation.arguments.contains("--directory")
                && invocation.arguments.contains { $0.contains(".worktreeinclude") }
        })
        let excludeFiles = includeFileInvocation.arguments.filter { $0.hasPrefix("--exclude-from=") }

        #expect(diagnostics.isEmpty)
        #expect(excludeFiles.count == 2)
        #expect(includeFileInvocation.arguments.count < 12)
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("node_modules/pkg-299").path
        ))
    }
}
