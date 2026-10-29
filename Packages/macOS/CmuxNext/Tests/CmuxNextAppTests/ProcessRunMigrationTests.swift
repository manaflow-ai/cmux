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
        // An export writes only its scratch folder: a cancel may stop it.
        #expect(request.onCancel == .stop)

        // An import fills the Chief home's memory: a cancel never stops it half way.
        try await tool.importText(muxHome: URL(fileURLWithPath: "/m"), from: URL(fileURLWithPath: "/in"))
        let imported = try #require(processes.requests.last)
        #expect(imported.arguments == ["memory", "import", "--mux-home", "/m", "/in"])
        #expect(imported.onCancel == .finish)
        #expect(imported.timeout == nil)

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

    /// cx-mb1e0: the bound is the App's, not a reader's. Two readers made apart (each chat header makes its own)
    /// on the App's one runner never have more than two gh running together; the rest start as slots free.
    @Test func separateReadersShareTheAppsTwoGitHubRuns() async throws {
        let view = #"{"url":"https://github.com/o/r/pull/7","number":7,"title":"Retry","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"statusCheckRollup":[]}"#
        let release = FirstOutcome<Void>()
        let (startStream, started) = AsyncStream.makeStream(of: Void.self)
        let (askStream, asked) = AsyncStream.makeStream(of: Void.self)
        let running = RunningCounts()
        let gh = RecordingProcessRunner { _ in
            await running.start()
            started.yield()
            await release.value()
            await running.end()
            return ProcessOutcome(status: 0, exited: true, output: Data(view.utf8))
        }
        let bounded = BoundedProcessRunner(gh, atOnce: 2)
        let app = RecordingProcessRunner { request in
            asked.yield()
            return try await bounded.outcome(of: request)
        }
        let readers = [AgentChatPullRequestReader(gh: "/opt/gh", processes: app), AgentChatPullRequestReader(gh: "/opt/gh", processes: app)]
        let reads = (0..<6).map { index in Task { await readers[index % 2].read(in: "/repo\(index)")?.number } }
        var asks = 0
        for await _ in askStream {
            asks += 1
            if asks == 6 { break }
        }
        var starts = 0
        for await _ in startStream {
            starts += 1
            if starts == 2 { break }
        }
        // All six asked and two run. Without a shared bound the other four would start now (at once, with no slot
        // to wait for); with it they wait, whichever reader asked, so this holds however long the yields take.
        for _ in 0..<20 { await Task.yield() }
        #expect(await running.started == 2)
        release.resolve(())
        for read in reads { #expect(await read.value == 7) }
        #expect(await running.most <= 2)
        #expect(await running.started == 6)
        // The App's reads default to that bound.
        #expect(AgentPullRequestReads(mainWork: MainWorkScheduler(budget: MainFrameBudget())).reader.processes is BoundedProcessRunner)
    }

    /// A real child through ``AsyncProcess``, from the main actor: the spawn and the wait make no blocking call on
    /// main, and the child runs at its request's QoS (`ps` reports a background child below a user-initiated one).
    @Test func aRealChildRunsAtItsRequestsPriorityAndNeverBlocksMain() async throws {
        func schedulingPriority(_ stated: WorkPriority) async throws -> Int? {
            let request = ProcessRequest(URL(fileURLWithPath: "/bin/sh"), ["-c", "/bin/ps -o pri= -p $$"], priority: stated)
            let outcome = try await AsyncProcess().run(request)
            return Int(outcome.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var low: Int?, high: Int?
        let sites = await mainThreadSites {
            low = try? await schedulingPriority(.idle)
            high = try? await schedulingPriority(.userBlocking)
        }
        #expect(sites.isEmpty, "\(sites)")
        let background = try #require(low), userInitiated = try #require(high)
        #expect(background < userInitiated, "idle child at \(background), userBlocking child at \(userInitiated)")
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
            target = try? await FileOperator(work: BackgroundWork(label: "test.file-operator"), processes: processes).compress([file], archiveName: "Archive")
        }
        #expect(sites.isEmpty, "\(sites)")
        #expect(target?.lastPathComponent == "a.txt.zip")
        let request = try #require(processes.requests.first)
        #expect(request.executable.path == "/usr/bin/ditto")
        #expect(request.arguments == ["-c", "-k", "--sequesterRsrc", file.path, folder.appendingPathComponent("a.txt.zip").path])
        #expect(request.priority == .userVisible)

        let failing = RecordingProcessRunner { _ in ProcessOutcome(status: 1, exited: true, output: Data(), errorOutput: Data("disk full".utf8)) }
        await #expect(throws: FileBrowserError.failed("disk full")) {
            _ = try await FileOperator(work: BackgroundWork(label: "test.file-operator"), processes: failing).compress([file], archiveName: "Archive")
        }
    }

    @Test func findInDirectoryAndDiffLaunchAtTheirPriorities() {
        #expect(RipgrepSearch.searchLauncher().childPriority == .userBlocking)
        let diff = DiffSidecarLauncher(sidecar: URL(fileURLWithPath: "/s"), cmux: URL(fileURLWithPath: "/c"), root: URL(fileURLWithPath: "/r"))
        #expect(diff.launcher.childPriority == .userVisible)
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

    /// A stand-in rg: it prints one `--json` match and exits. The search spawns it through the launcher it is
    /// given, off the main thread, and parses its match.
    @Test func findInDirectorySpawnsRgOffTheMainThreadAndReadsItsMatch() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rg = folder.appendingPathComponent("rg")
        let match = #"{"type":"match","data":{"path":{"text":"\#(folder.path)/a.txt"},"lines":{"text":"hello\n"},"line_number":3,"submatches":[{"start":0}]}}"#
        try "#!/bin/sh\nprintf '%s\\n' '\(match)'\n".write(to: rg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rg.path)
        let launcher = CmuxNextWakeups.ProcessLauncher(label: "test.find-in-directory", priority: .userBlocking)
        var outcome: RipgrepSearch.Outcome?
        let sites = await mainThreadSites {
            outcome = await RipgrepSearch.run(rg, query: "hello", root: folder.path, launcher: launcher)
        }
        #expect(sites.isEmpty, "\(sites)")
        guard case .matches(let matches, let limited) = outcome else {
            Issue.record("rg's match was not read: \(String(describing: outcome))")
            return
        }
        #expect(!limited)
        #expect(matches.map(\.relativePath) == ["a.txt"])
        #expect(matches.first?.line == 3)
    }

    /// A Compress that fails (or is stopped) part way leaves no partial archive behind.
    @Test func aFailedCompressRemovesItsPartialArchive() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        // ditto writes part of the archive, then fails.
        let processes = RecordingProcessRunner { request in
            if let archive = request.arguments.last { try Data("PK".utf8).write(to: URL(fileURLWithPath: archive)) }
            return ProcessOutcome(status: 1, exited: false, output: Data(), errorOutput: Data())
        }
        await #expect(throws: FileBrowserError.self) {
            _ = try await FileOperator(work: BackgroundWork(label: "test.file-operator"), processes: processes).compress([file], archiveName: "Archive")
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.txt.zip").path))
        #expect(processes.requests.first?.onCancel == .stop)
    }
}

/// How many fake gh runs run now, the most that ran at once, and how many started.
private actor RunningCounts {
    private var now = 0
    private(set) var most = 0
    private(set) var started = 0

    func start() {
        now += 1
        started += 1
        most = max(most, now)
    }

    func end() {
        now -= 1
    }
}
