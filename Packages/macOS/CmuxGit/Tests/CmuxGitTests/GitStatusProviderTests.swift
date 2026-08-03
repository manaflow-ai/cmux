import CmuxFoundation
import Foundation
import Testing

@testable import CmuxGit

@Suite(.serialized)
struct GitStatusProviderTests {
    @Test
    func statusQueryDoesNotRefreshGitIndex() async throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        try Self.initializeRepo(at: repoURL)

        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "tracked.txt"], in: repoURL)
        try Self.runGit(["commit", "-m", "initial"], in: repoURL)

        let indexURL = repoURL.appendingPathComponent(".git/index")
        let indexBeforeStatus = try Data(contentsOf: indexURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: trackedURL.path
        )

        _ = await GitStatusProvider().fetchStatus(directory: repoURL.path)

        let indexAfterStatus = try Data(contentsOf: indexURL)
        #expect(indexAfterStatus == indexBeforeStatus)
    }

    @Test
    func statusQueryPreservesQuotedAndEscapedFilenames() async throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try Self.initializeRepo(at: repoURL)

        let nestedURL = repoURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        let trackedURL = nestedURL.appendingPathComponent("quoted \"name\" and \\ slash.txt")
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "."], in: repoURL)
        try Self.runGit(["commit", "-m", "initial"], in: repoURL)
        try "modified contents\n".write(to: trackedURL, atomically: true, encoding: .utf8)

        let status = await GitStatusProvider().fetchStatus(directory: nestedURL.path)

        #expect(status[trackedURL.path] == .some(.modified))
    }

    @Test
    func statusQueryExcludesSiblingPathPrefixes() async throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try Self.initializeRepo(at: repoURL)

        let explorerRootURL = repoURL.appendingPathComponent("work", isDirectory: true)
        let siblingURL = repoURL.appendingPathComponent("workspace-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: explorerRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: true)

        let visibleURL = explorerRootURL.appendingPathComponent("tracked.txt")
        let siblingFileURL = siblingURL.appendingPathComponent("tracked.txt")
        try "one\n".write(to: visibleURL, atomically: true, encoding: .utf8)
        try "one\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "."], in: repoURL)
        try Self.runGit(["commit", "-m", "initial"], in: repoURL)
        try "visible modified contents\n".write(to: visibleURL, atomically: true, encoding: .utf8)
        try "sibling modified contents\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)

        let status = await GitStatusProvider().fetchStatus(directory: explorerRootURL.path)

        #expect(status[visibleURL.path] == .some(.modified))
        #expect(status[siblingFileURL.path] == nil)
        #expect(status[siblingURL.path] == nil)
    }

    @Test
    func statusQueryPreservesExplorerSymlinkNamespace() async throws {
        let containerURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: containerURL) }

        let repoURL = containerURL.appendingPathComponent("repo", isDirectory: true)
        let aliasURL = containerURL.appendingPathComponent("repo-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: repoURL)
        try Self.initializeRepo(at: repoURL)

        let realExplorerURL = repoURL.appendingPathComponent("work", isDirectory: true)
        let aliasExplorerURL = aliasURL.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: realExplorerURL, withIntermediateDirectories: true)
        let realTrackedURL = realExplorerURL.appendingPathComponent("tracked.txt")
        let aliasTrackedURL = aliasExplorerURL.appendingPathComponent("tracked.txt")
        try "one\n".write(to: realTrackedURL, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "."], in: repoURL)
        try Self.runGit(["commit", "-m", "initial"], in: repoURL)
        try "modified contents\n".write(to: realTrackedURL, atomically: true, encoding: .utf8)

        let status = await GitStatusProvider().fetchStatus(directory: aliasExplorerURL.path)

        #expect(status[aliasTrackedURL.path] == .some(.modified))
        #expect(status[realTrackedURL.path] == nil)
    }

    @Test
    func statusQueryMapsTypeChangedAndUnmergedEntries() async throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let fakeGitURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            if [ "${CMUX_TEST_GIT_ENV:-}" != "expected" ]; then
                exit 3
            fi
            if [ "${GIT_OPTIONAL_LOCKS:-}" != "0" ]; then
                exit 4
            fi
            case "$1 $2" in
            "rev-parse --show-toplevel")
                printf '%s\n' "$CMUX_TEST_REPO_ROOT"
                ;;
            "status --porcelain=v1")
                printf ' T type-change.txt\0UU conflicted.txt\0'
                ;;
            *)
                exit 2
                ;;
            esac
            """#,
            named: "fake-git",
            in: repoURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_GIT_ENV"] = "expected"
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.path

        let status = await GitStatusProvider(
            gitExecutableURL: fakeGitURL,
            environment: environment
        ).fetchStatus(directory: repoURL.path)

        #expect(status[repoURL.appendingPathComponent("type-change.txt").path] == .some(.modified))
        #expect(status[repoURL.appendingPathComponent("conflicted.txt").path] == .some(.modified))
    }

    @Test
    func statusQueriesForwardTheBoundedProcessDeadline() async throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }
        let runner = RecordingGitStatusCommandRunner(
            results: [
                CommandResult(
                    stdout: "\(repoURL.path)\n",
                    stderr: "",
                    exitStatus: 0,
                    timedOut: false,
                    executionError: nil
                ),
                CommandResult(
                    stdout: nil,
                    stderr: nil,
                    exitStatus: nil,
                    timedOut: true,
                    executionError: nil
                ),
            ]
        )
        let expectedTimeout: TimeInterval = 0.125

        let status = await GitStatusProvider(
            commandRunner: runner,
            processTimeout: expectedTimeout
        ).fetchStatus(directory: repoURL.path)
        let recordedArguments = await runner.recordedArguments()
        let recordedTimeouts = await runner.recordedTimeouts()

        #expect(status.isEmpty)
        #expect(recordedArguments.count == 2)
        #expect(recordedTimeouts == [expectedTimeout, expectedTimeout])
        #expect(recordedArguments == [
            ["rev-parse", "--show-toplevel"],
            ["status", "--porcelain=v1", "-z"],
        ])
    }

    @Test
    func sshStatusQueryUsesInjectedProcessEnvironment() async throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let fakeSSHURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            if [ "${CMUX_TEST_SSH_ENV:-}" != "expected" ]; then
                exit 3
            fi
            printf '%s\n\000 M remote.txt\000' "$CMUX_TEST_REPO_ROOT"
            """#,
            named: "fake-ssh",
            in: repoURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.path
        environment["CMUX_TEST_SSH_ENV"] = "expected"

        let status = await GitStatusProvider(
            sshExecutableURL: fakeSSHURL,
            environment: environment
        ).fetchStatusSSH(
            directory: repoURL.path,
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: []
        )

        #expect(status[repoURL.appendingPathComponent("remote.txt").path] == .some(.modified))
    }

    @Test
    func sshStatusFramingAllowsLegacyMarkerInRepositoryPath() async throws {
        let containerURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: containerURL) }
        let repoURL = containerURL.appendingPathComponent(
            "repo---GIT_STATUS---\ncollision",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

        let fakeSSHURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            printf '%s\n\000 M remote.txt\000' "$CMUX_TEST_REPO_ROOT"
            """#,
            named: "fake-ssh",
            in: containerURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.path

        let status = await GitStatusProvider(
            sshExecutableURL: fakeSSHURL,
            environment: environment
        ).fetchStatusSSH(
            directory: repoURL.path,
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: []
        )

        #expect(status[repoURL.appendingPathComponent("remote.txt").path] == .some(.modified))
    }

    @Test
    func sshStatusQueryOverridesHostConfiguredRemoteCommand() async throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let argumentLog = repoURL.appendingPathComponent("ssh-argv.txt")
        let fakeSSHURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            for arg in "$@"; do printf '%s\n' "$arg"; done > "$CMUX_TEST_SSH_ARGV_LOG"
            printf '%s\n\000 M remote.txt\000' "$CMUX_TEST_REPO_ROOT"
            """#,
            named: "fake-ssh",
            in: repoURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.path
        environment["CMUX_TEST_SSH_ARGV_LOG"] = argumentLog.path

        let status = await GitStatusProvider(
            sshExecutableURL: fakeSSHURL,
            environment: environment
        ).fetchStatusSSH(
            directory: repoURL.path,
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: []
        )

        #expect(status[repoURL.appendingPathComponent("remote.txt").path] == .some(.modified))
        let arguments = try String(contentsOf: argumentLog, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let overrideIndex = arguments.indices.dropLast().first {
            arguments[$0] == "-o" && arguments[$0 + 1] == "RemoteCommand=none"
        }
        let destinationIndex = arguments.firstIndex(of: "example.invalid")
        #expect(overrideIndex != nil, "\(arguments)")
        #expect(destinationIndex != nil, "\(arguments)")
        if let overrideIndex, let destinationIndex {
            #expect(overrideIndex < destinationIndex)
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private static func writeExecutableScript(
        _ contents: String,
        named name: String,
        in directory: URL
    ) throws -> URL {
        let scriptURL = directory.appendingPathComponent(name)
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private static func initializeRepo(at repoURL: URL) throws {
        try Self.runGit(["init"], in: repoURL)
        try Self.runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try Self.runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
    }

    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }
}

private actor RecordingGitStatusCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private var arguments: [[String]] = []
    private var timeouts: [TimeInterval?] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        self.arguments.append(arguments)
        timeouts.append(timeout)
        guard !results.isEmpty else {
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: "missing stub result"
            )
        }
        return results.removeFirst()
    }

    func recordedArguments() -> [[String]] {
        arguments
    }

    func recordedTimeouts() -> [TimeInterval?] {
        timeouts
    }
}
