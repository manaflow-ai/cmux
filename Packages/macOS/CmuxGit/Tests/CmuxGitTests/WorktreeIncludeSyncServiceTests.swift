import CmuxFoundation
import Foundation
import Testing
@testable import CmuxGit

@Suite("Worktree include sync")
struct WorktreeIncludeSyncServiceTests {
    @Test("missing .worktreeinclude is a no-op")
    func missingIncludeIsNoOp() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)

        #expect(diagnostics.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("Git patterns select untracked files and skip tracked matches")
    func gitPatternsAndTrackedFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try initializeGitRepository(at: source)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("config", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("config", isDirectory: true),
            withIntermediateDirectories: true
        )
        try ".env\nconfig/app.local\nconfig/skip.local\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "# local worktree state\n.env\nconfig/*.local\n!config/skip.local\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "secret=value\n".write(
            to: source.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try "local\n".write(
            to: source.appendingPathComponent("config/app.local"),
            atomically: true,
            encoding: .utf8
        )
        try "skip\n".write(
            to: source.appendingPathComponent("config/skip.local"),
            atomically: true,
            encoding: .utf8
        )
        try "source tracked\n".write(
            to: source.appendingPathComponent("config/tracked.local"),
            atomically: true,
            encoding: .utf8
        )
        try "destination tracked\n".write(
            to: destination.appendingPathComponent("config/tracked.local"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "config/tracked.local"], in: source)

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)

        #expect(diagnostics.isEmpty)
        #expect(try contents(at: destination.appendingPathComponent(".env")) == "secret=value\n")
        #expect(try contents(at: destination.appendingPathComponent("config/app.local")) == "local\n")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("config/skip.local").path))
        #expect(try contents(at: destination.appendingPathComponent("config/tracked.local")) == "destination tracked\n")
    }

    @Test("directory patterns copy nested trees")
    func directoryPatternCopiesNestedTree() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try initializeGitRepository(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("node_modules/pkg/lib", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "node_modules/\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "node_modules/\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "module\n".write(
            to: source.appendingPathComponent("node_modules/pkg/lib/index.js"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)

        #expect(diagnostics.isEmpty)
        #expect(
            try contents(at: destination.appendingPathComponent("node_modules/pkg/lib/index.js")) == "module\n"
        )
    }

    @Test("in-repository destinations cannot recursively copy their containing subtree")
    func selfCopyGuard() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = source.appendingPathComponent(".cmux/worktrees/new", isDirectory: true)
        try initializeGitRepository(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent(".cmux/worktrees/old", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("local/nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent(".cmux/settings", isDirectory: true),
            withIntermediateDirectories: true
        )
        try ".cmux/settings/\n.cmux/worktrees/old/\nlocal/\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try ".cmux/settings/\n.cmux/worktrees/old/\nlocal/\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "old\n".write(
            to: source.appendingPathComponent(".cmux/worktrees/old/secret"),
            atomically: true,
            encoding: .utf8
        )
        try "new\n".write(
            to: destination.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8
        )
        try "copy me\n".write(
            to: source.appendingPathComponent("local/nested/value"),
            atomically: true,
            encoding: .utf8
        )
        try "setting\n".write(
            to: source.appendingPathComponent(".cmux/settings/value"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)

        #expect(diagnostics.contains { $0.contains("Skipped unsafe") })
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(".cmux/worktrees").path))
        #expect(try contents(at: destination.appendingPathComponent("marker")) == "new\n")
        #expect(try contents(at: destination.appendingPathComponent("local/nested/value")) == "copy me\n")
        #expect(try contents(at: destination.appendingPathComponent(".cmux/settings/value")) == "setting\n")
    }

    @Test("direct-child destinations copy safe matches and skip their own subtree")
    func directChildDestination() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = source.appendingPathComponent("new-worktree", isDirectory: true)
        try initializeGitRepository(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try ".env\nnew-worktree/\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try ".env\nnew-worktree/\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "secret=value\n".write(
            to: source.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try "keep\n".write(
            to: destination.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)

        #expect(diagnostics.contains { $0.contains("Skipped unsafe") && $0.contains("new-worktree/") })
        #expect(try contents(at: destination.appendingPathComponent(".env")) == "secret=value\n")
        #expect(try contents(at: destination.appendingPathComponent("marker")) == "keep\n")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("new-worktree").path))
    }

    @Test("matching paths must also be ignored by the repository")
    func unignoredMatchIsSkipped() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try initializeGitRepository(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "ignored.env\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored.env\nunignored.env\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored\n".write(
            to: source.appendingPathComponent("ignored.env"),
            atomically: true,
            encoding: .utf8
        )
        try "unignored\n".write(
            to: source.appendingPathComponent("unignored.env"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)

        #expect(diagnostics.isEmpty)
        #expect(try contents(at: destination.appendingPathComponent("ignored.env")) == "ignored\n")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("unignored.env").path))
    }

    @Test("copy failures are diagnostics and do not stop later copies")
    func copyFailuresAreNonFatal() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try initializeGitRepository(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try ".env\nsettings.local\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try ".env\nsettings.local\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "source secret\n".write(
            to: source.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try "destination secret\n".write(
            to: destination.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try "settings\n".write(
            to: source.appendingPathComponent("settings.local"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)

        #expect(diagnostics.contains { $0.contains("Could not copy") && $0.contains(".env") })
        #expect(try contents(at: destination.appendingPathComponent(".env")) == "destination secret\n")
        #expect(try contents(at: destination.appendingPathComponent("settings.local")) == "settings\n")
    }

    @Test("standard-ignore checks are candidate-scoped and time bounded")
    func standardIgnoreChecksAreBounded() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let runner = CandidateFilteringCommandRunner()
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("node_modules/pkg", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "node_modules/\n.env\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "module\n".write(
            to: source.appendingPathComponent("node_modules/pkg/index.js"),
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

        #expect(diagnostics.isEmpty)
        #expect(try contents(at: destination.appendingPathComponent(".env")) == "secret=value\n")
        #expect(try contents(at: destination.appendingPathComponent("node_modules/pkg/index.js")) == "module\n")
        #expect(invocations.allSatisfy { $0.timeout != nil })
        let standardIgnoreInvocations = invocations.filter { $0.arguments.contains("--exclude-standard") }
        #expect(!standardIgnoreInvocations.isEmpty)
        #expect(standardIgnoreInvocations.allSatisfy { invocation in
            guard let separator = invocation.arguments.firstIndex(of: "--") else { return false }
            let pathspecs = invocation.arguments.suffix(from: invocation.arguments.index(after: separator))
            return !pathspecs.isEmpty && pathspecs.allSatisfy { $0.hasPrefix(":(top,literal)") }
        })
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktree-include-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func initializeGitRepository(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try runGit(["init"], in: directory)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WorktreeIncludeSyncServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
    }

    private func contents(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

private actor CandidateFilteringCommandRunner: CommandRunning {
    struct Invocation: Sendable {
        let arguments: [String]
        let timeout: TimeInterval?
    }

    private var recordedInvocations: [Invocation] = []

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        recordedInvocations.append(Invocation(arguments: arguments, timeout: timeout))
        let isStandardIgnoreCheck = arguments.contains("--exclude-standard")
        let isDirectoryQuery = arguments.contains("--directory")
        let literalPathspecs = arguments.compactMap { argument -> String? in
            let prefix = ":(top,literal)"
            guard argument.hasPrefix(prefix) else { return nil }
            return String(argument.dropFirst(prefix.count))
        }

        let stdout: String
        if isStandardIgnoreCheck {
            stdout = literalPathspecs.compactMap { path in
                if path == "node_modules/" { return "node_modules/" }
                if path == ".env" { return ".env" }
                return nil
            }.joined(separator: "\0") + (literalPathspecs.isEmpty ? "" : "\0")
        } else if isDirectoryQuery {
            stdout = "node_modules/\0"
        } else {
            stdout = ".env\0"
        }
        return CommandResult(
            stdout: stdout,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }

    func invocations() -> [Invocation] {
        recordedInvocations
    }
}
