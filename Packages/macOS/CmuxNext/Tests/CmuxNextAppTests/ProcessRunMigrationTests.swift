@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextCompat
@testable import CmuxNextDiff
import CmuxNextFiles
import CmuxNextFilesUI
@testable import CmuxNextHomeEngine
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The child processes of plans/cmux-next/chrome-parity/p02-threads.md task 038 (HomeEngine, AgentPane, App,
/// Files, FilesUI, Diff): a run-to-end child goes through ``ProcessRunning`` (AsyncProcess) with the priority its
/// caller states, a long-lived one through a ``ProcessLauncher`` at its priority, and none of them makes a
/// blocking call on the main thread. A recording fake stands in for the child; the Diff run spawns a real one.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ProcessRunMigrationTests {
    /// The blocking seams `body` ran on the main thread, by call site.
    func mainThreadSites(_ body: () async -> Void) async -> [String] {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable(mode: .record)
        await BlockingViolationTable.$scoped.withValue(table) { await body() }
        await table.flush()
        return table.sites.filter { $0.context == .main }.map(\.location)
        #else
        await body()
        return []
        #endif
    }

    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-process-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func chiefUsageRunsAtUserVisibleAndReportsItsError() async throws {
        let tool = URL(fileURLWithPath: "/opt/optchat-chief")
        let processes = RecordingProcessRunner { _ in ProcessOutcome(status: 0, exited: true, output: Data("{}".utf8)) }
        var output = Data()
        let sites = await mainThreadSites {
            output = (try? await ChiefUsageTool(executable: tool, processes: processes).run(["usage"], muxHome: URL(fileURLWithPath: "/m"))) ?? Data()
        }
        #expect(sites.isEmpty, "\(sites)")
        #expect(output == Data("{}".utf8))
        let request = try #require(processes.requests.first)
        #expect(request.executable == tool)
        #expect(request.arguments == ["usage", "--mux-home", "/m", "--chiefs", "--json"])
        #expect(request.priority == .userVisible)
        #expect(request.errorOutput == .separate)

        let failing = RecordingProcessRunner { _ in ProcessOutcome(status: 2, exited: true, output: Data(), errorOutput: Data(" no ledger\n".utf8)) }
        await #expect(throws: ChiefUsageTool.Failure(status: 2, message: "no ledger")) {
            _ = try await ChiefUsageTool(executable: tool, processes: failing).run(["usage"], muxHome: URL(fileURLWithPath: "/m"))
        }
    }

    @Test func chiefMemoryRunsAtUserVisibleAndNamesTheToolsError() async throws {
        let processes = RecordingProcessRunner()
        let tool = BundledChiefMemoryTool(executable: URL(fileURLWithPath: "/opt/optchat-chief"), processes: processes)
        try await tool.exportText(muxHome: URL(fileURLWithPath: "/m"), to: URL(fileURLWithPath: "/out"))
        let request = try #require(processes.requests.first)
        #expect(request.arguments == ["memory", "export", "--text", "/out", "--mux-home", "/m"])
        #expect(request.priority == .userVisible)

        let failing = BundledChiefMemoryTool(executable: URL(fileURLWithPath: "/opt/optchat-chief"), processes: RecordingProcessRunner { _ in
            ProcessOutcome(status: 1, exited: true, output: Data(), errorOutput: Data("store busy".utf8))
        })
        do {
            try await failing.importText(muxHome: URL(fileURLWithPath: "/m"), from: URL(fileURLWithPath: "/in"))
            Issue.record("a failed import threw nothing")
        } catch {
            #expect(error.localizedDescription.contains("store busy"))
        }
    }

    @Test func theBrainHostShellRunsInTheChiefHomeAtUserVisible() async throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let processes = RecordingProcessRunner { _ in ProcessOutcome(status: 0, exited: true, output: Data("4242\n".utf8)) }
        let host = HomeBrainHost(executable: URL(fileURLWithPath: "/opt/optchat-chief"), muxHome: home, daemonSocket: "/tmp/d.sock",
                                 controlSocket: "/tmp/c.sock", acpmux: nil, processes: processes)
        #expect(await host.launch(agentToken: "token") == 4242)
        let request = try #require(processes.requests.first)
        #expect(request.executable.path == "/bin/sh")
        #expect(request.directory == home)
        #expect(request.priority == .userVisible)
        #expect(request.input == nil)
        #expect(request.errorOutput == .discard)
    }

    @Test func buildHomeAdoptionRunsToItsEndAtUserBlocking() async throws {
        let processes = RecordingProcessRunner { _ in ProcessOutcome(status: 0, exited: true, output: Data("adopted\n".utf8)) }
        await BuildHomeAdoption.adopt(cli: URL(fileURLWithPath: "/opt/cmux"), environment: ["HOME": "/h"], processes: processes,
                                      clock: ManualClock())
        let request = try #require(processes.requests.first)
        #expect(request.arguments == ["__adopt-build-homes"])
        #expect(request.environment == ["HOME": "/h"])
        #expect(request.priority == .userBlocking)
        // Never stopped half way: no timeout, and a cancel does not stop it.
        #expect(request.timeout == nil)
        #expect(request.onCancel == .finish)
        #expect(request.errorOutput == .merge)
    }

    @Test func pullRequestReadsRunGitHubCLIAtBestEffortWithTheirDeadline() async throws {
        let view = #"{"url":"https://github.com/o/r/pull/7","number":7,"title":"Retry","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"statusCheckRollup":[]}"#
        let processes = RecordingProcessRunner { _ in ProcessOutcome(status: 0, exited: true, output: Data(view.utf8)) }
        let reader = AgentChatPullRequestReader(gh: "/opt/gh", timeout: .seconds(7), environment: ["HOME": "/h", "PATH": "/usr/bin"],
                                                processes: processes)
        var number: Int?
        let sites = await mainThreadSites { number = await reader.read(in: "/repo")?.number }
        #expect(sites.isEmpty, "\(sites)")
        #expect(number == 7)
        let request = try #require(processes.requests.first)
        #expect(request.executable.path == "/opt/gh")
        #expect(request.directory?.path == "/repo")
        #expect(request.timeout == .seconds(7))
        #expect(request.priority == .bestEffort)
        #expect(request.environment?["GH_PROMPT_DISABLED"] == "1")

        // A failed gh, or one stopped at its deadline, is no answer.
        let failed = AgentChatPullRequestReader(gh: "/opt/gh", processes: RecordingProcessRunner { _ in
            ProcessOutcome(status: 1, exited: true, output: Data(view.utf8))
        })
        #expect(await failed.read(in: "/repo") == nil)
        let late = AgentChatPullRequestReader(gh: "/opt/gh", processes: RecordingProcessRunner { _ in throw ProcessFailure.timedOut })
        #expect(await late.read(in: "/repo") == nil)
    }

    @Test func aChatMoveRunsAtUserBlockingAndIsNeverStoppedEarly() async throws {
        let processes = RecordingProcessRunner { _ in
            ProcessOutcome(status: 0, exited: true, output: Data(#"{"sessionId":"s2"}"#.utf8), errorOutput: Data("note".utf8))
        }
        var result: (status: Int32, stdout: Data, stderr: Data)?
        let sites = await mainThreadSites {
            result = try? await SessionTransferService.runToEnd(URL(fileURLWithPath: "/opt/acpmux"), ["transfer"], environment: [:],
                                                                limit: .seconds(240), processes: processes, clock: ManualClock())
        }
        #expect(sites.isEmpty, "\(sites)")
        #expect(result?.status == 0)
        #expect(result?.stdout == Data(#"{"sessionId":"s2"}"#.utf8))
        #expect(result?.stderr == Data("note".utf8))
        let request = try #require(processes.requests.first)
        #expect(request.priority == .userBlocking)
        #expect(request.onCancel == .finish)
        #expect(request.timeout == nil)
        #expect(request.errorOutput == .separate)

        let missing = RecordingProcessRunner { _ in throw ProcessFailure.launch("no such file") }
        do {
            _ = try await SessionTransferService.runToEnd(URL(fileURLWithPath: "/opt/acpmux"), ["transfer"], environment: [:],
                                                          limit: .seconds(240), processes: missing, clock: ManualClock())
            Issue.record("a move that could not start threw nothing")
        } catch SessionTransferService.Failure.chatNotMoved(let message) {
            #expect(message.contains("no such file"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func compressRunsDittoAtUserVisibleAndReportsItsError() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        let processes = RecordingProcessRunner()
        var target: URL?
        let sites = await mainThreadSites {
            target = try? await FileOperator(processes: processes).compress([file], archiveName: "Archive")
        }
        #expect(sites.isEmpty, "\(sites)")
        #expect(target?.lastPathComponent == "a.txt.zip")
        let request = try #require(processes.requests.first)
        #expect(request.executable.path == "/usr/bin/ditto")
        #expect(request.arguments == ["-c", "-k", "--sequesterRsrc", file.path, folder.appendingPathComponent("a.txt.zip").path])
        #expect(request.priority == .userVisible)

        let failing = RecordingProcessRunner { _ in ProcessOutcome(status: 1, exited: true, output: Data(), errorOutput: Data("disk full".utf8)) }
        await #expect(throws: FileBrowserError.failed("disk full")) {
            _ = try await FileOperator(processes: failing).compress([file], archiveName: "Archive")
        }
    }

    @Test func findInDirectoryAndDiffLaunchAtTheirPriorities() {
        #expect(RipgrepSearch.searchLauncher().priority == .userBlocking)
        let diff = DiffSidecarLauncher(sidecar: URL(fileURLWithPath: "/s"), cmux: URL(fileURLWithPath: "/c"), root: URL(fileURLWithPath: "/r"))
        #expect(diff.launcher.priority == .userVisible)
    }

    /// A stand-in sidecar: it prints the ready marker, then echoes the request it reads back as its reply.
    @Test func aDiffSidecarSpawnsOffTheMainThreadAndAnswers() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sidecar = folder.appendingPathComponent("sidecar")
        try "#!/bin/sh\nprintf 'cmux-diff-sidecar-process-group-ready\\n' >&2\nexec /bin/cat\n".write(to: sidecar, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sidecar.path)
        let launcher = CmuxNextWakeups.ProcessLauncher(label: "test.diff-sidecar", priority: .userVisible)
        var reply: Data?
        let sites = await mainThreadSites {
            reply = try? await DiffSidecarProcess.run(executable: sidecar, arguments: [], request: Data(#"{"op":"ping"}"#.utf8),
                                                      launcher: launcher)
        }
        #expect(sites.isEmpty, "\(sites)")
        #expect(reply == Data(#"{"op":"ping"}"#.utf8))
    }

    @Test func aDiffSidecarThatCannotStartFailsAtOnce() async {
        let launcher = CmuxNextWakeups.ProcessLauncher(label: "test.diff-sidecar", priority: .userVisible)
        await #expect(throws: DiffSidecarError.startFailed) {
            _ = try await DiffSidecarProcess.run(executable: URL(fileURLWithPath: "/nonexistent/cmux-diff-sidecar"), arguments: [],
                                                 request: Data("{}".utf8), launcher: launcher)
        }
    }
}
