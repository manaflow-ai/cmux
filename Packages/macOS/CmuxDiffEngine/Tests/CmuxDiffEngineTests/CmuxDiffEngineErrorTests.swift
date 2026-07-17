import CmuxDiffEngine
import CmuxFoundation
import Foundation
import Testing

@Suite
struct CmuxDiffEngineErrorTests {
    @Test
    func mapsRepositoryProbeFailureToNotGitRepository() async {
        let engine = CmuxDiffEngine(commandRunner: FakeCommandRunner.failure("not a repository"))
        await #expect(throws: DiffEngineError.notGitRepository) {
            try await engine.summary(
                repositoryPath: "/tmp",
                baseSpec: DiffBaseSpec(kind: .workingTree),
                ignoreWhitespace: false
            )
        }
    }

    @Test
    func reportsMissingLastTurnBaselineBeforeDiffCommands() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("base\n", path: "file.txt")
        _ = try repo.commitAll()
        await #expect(throws: DiffEngineError.baselineUnavailable) {
            try await CmuxDiffEngine().summary(
                repositoryPath: repo.root.path,
                baseSpec: DiffBaseSpec(kind: .lastTurn),
                ignoreWhitespace: false
            )
        }
    }

    @Test
    func rejectsEscapingContextPath() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        await #expect(throws: DiffEngineError.invalidPath("../secret")) {
            try await CmuxDiffEngine().contextRows(
                repositoryPath: repo.root.path,
                path: "../secret",
                startLine: 1,
                endLine: 1
            )
        }
    }

    @Test
    func surfacesInjectedGitFailureAfterRepositoryResolution() async {
        let runner = FakeCommandRunner { directory, arguments in
            if arguments.contains("--show-toplevel") {
                return CommandResult(
                    stdout: directory + "\n",
                    stderr: "",
                    exitStatus: 0,
                    timedOut: false,
                    executionError: nil
                )
            }
            if arguments.contains("rev-parse") {
                return CommandResult(
                    stdout: "",
                    stderr: "missing HEAD",
                    exitStatus: 128,
                    timedOut: false,
                    executionError: nil
                )
            }
            return CommandResult(
                stdout: nil,
                stderr: "hash failure",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            )
        }
        do {
            _ = try await CmuxDiffEngine(commandRunner: runner).summary(
                repositoryPath: "/tmp",
                baseSpec: DiffBaseSpec(kind: .workingTree),
                ignoreWhitespace: false
            )
            Issue.record("Expected command failure")
        } catch let error as DiffEngineError {
            guard case .commandFailed(_, let diagnostic) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(diagnostic == "hash failure")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
