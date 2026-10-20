import CmuxNextVSCodeServer
import Foundation
import Testing

/// The inline VS Code server (`palette.openFolderInVSCodeInline`, Stop and Restart VS Code Inline
/// Server): one `serve-web` process on 127.0.0.1 for the whole app, started on first use, shared by
/// every caller while it runs, and stopped or restarted on request. A fake launcher stands in for
/// the process; the token file is real, in a temporary directory.
@Suite struct VSCodeServeWebServiceTests {
    static let vscode = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-vscode-\(UUID().uuidString.prefix(8))", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A VS Code install with a trusted cached `code-server`.
    func planner() -> VSCodeServeWebLaunchPlanner {
        VSCodeServeWebLaunchPlanner(
            homeDirectory: root, environment: ["PATH": "/usr/bin", "NODE_OPTIONS": "--inspect"],
            isExecutable: { $0.hasSuffix("bin/code-server") },
            data: { $0.path.hasSuffix("lru.json") ? Data(#"["trusted"]"#.utf8) : nil },
            contents: { _ in [] }, modificationDate: { _ in nil },
            executableTrust: { _ in true }
        )
    }

    func service(_ launcher: FakeServeWebLauncher) -> VSCodeServeWebService {
        VSCodeServeWebService(planner: planner(), launcher: launcher, tokenDirectory: root, makeToken: { "tok123" })
    }

    func tokenFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("cmux-vscode-token-") }
    }

    @Test func theFirstCallStartsServeWebOnLoopbackWithAPrivateTokenFile() async throws {
        let launcher = FakeServeWebLauncher()
        let service = service(launcher)
        let url = try await service.url(vscode: Self.vscode)
        #expect(url.absoluteString == "http://127.0.0.1:50001/?tkn=tok123")
        let launch = try #require(await launcher.launches.first)
        #expect(launch.executableURL.lastPathComponent == "code-server")
        #expect(Array(launch.arguments.prefix(6)) == ["--accept-server-license-terms", "--host", "127.0.0.1", "--port", "0", "--connection-token-file"])
        #expect(launch.environment["ELECTRON_RUN_AS_NODE"] == nil)
        #expect(launch.environment["NODE_OPTIONS"] == nil, "VS Code's own Node must not inherit NODE_OPTIONS")
        #expect(launch.environment["VSCODE_NODE_OPTIONS"] == nil)
        let tokenFile = try #require(launch.arguments.last.map { URL(fileURLWithPath: $0) })
        #expect(try String(contentsOf: tokenFile, encoding: .utf8) == "tok123")
        let permissions = try FileManager.default.attributesOfItem(atPath: tokenFile.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600, "only this user can read the connection token")
        #expect(await service.isServing)
    }

    @Test func aRunningServerIsReusedAndConcurrentCallersShareOneLaunch() async throws {
        let launcher = FakeServeWebLauncher()
        let service = service(launcher)
        async let first = service.url(vscode: Self.vscode)
        async let second = service.url(vscode: Self.vscode)
        let urls = try await [first, second]
        #expect(urls[0] == urls[1])
        _ = try await service.url(vscode: Self.vscode)
        #expect(await launcher.launches.count == 1)
    }

    @Test func aFolderOpensThroughTheFolderQueryOfTheServerURL() async throws {
        let service = service(FakeServeWebLauncher())
        let url = try await service.url(vscode: Self.vscode, openingFolder: "/Users/me/My Project")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "tkn", value: "tok123")))
        #expect(items.filter { $0.name == "folder" } == [URLQueryItem(name: "folder", value: "/Users/me/My Project")])
    }

    @Test func stopTerminatesTheServerAndRemovesItsTokenAndTheNextCallStartsAgain() async throws {
        let launcher = FakeServeWebLauncher()
        let service = service(launcher)
        _ = try await service.url(vscode: Self.vscode)
        let process = try #require(await launcher.processes.first)
        #expect(try tokenFiles().count == 1)
        await service.stop()
        #expect(!process.isRunning)
        #expect(try tokenFiles().isEmpty)
        #expect(await !service.isServing)
        _ = try await service.url(vscode: Self.vscode)
        #expect(await launcher.launches.count == 2)
    }

    @Test func restartReplacesTheRunningServer() async throws {
        let launcher = FakeServeWebLauncher()
        let service = service(launcher)
        let before = try await service.url(vscode: Self.vscode)
        let after = try await service.restart(vscode: Self.vscode)
        let processes = await launcher.processes
        #expect(processes.count == 2)
        #expect(!processes[0].isRunning && processes[1].isRunning)
        #expect(before != after)
        #expect(try tokenFiles().count == 1)
    }

    @Test func aServerThatExitedOnItsOwnIsStartedAgain() async throws {
        let launcher = FakeServeWebLauncher()
        let service = service(launcher)
        _ = try await service.url(vscode: Self.vscode)
        try #require(await launcher.processes.first).terminate()
        #expect(await !service.isServing)
        _ = try await service.url(vscode: Self.vscode)
        #expect(await launcher.launches.count == 2)
        #expect(try tokenFiles().count == 1, "the dead server's token file is removed")
    }

    @Test func stopDuringStartupFailsTheWaitingCallerAndEndsTheLateServer() async throws {
        let launcher = FakeServeWebLauncher(holdsStart: true)
        let service = service(launcher)
        let waiting = Task { try await service.url(vscode: Self.vscode) }
        await launcher.waitForStart()
        await service.stop()
        await launcher.releaseStart()
        await #expect(throws: VSCodeServeWebError.stopped) { try await waiting.value }
        #expect(await launcher.processes.allSatisfy { !$0.isRunning })
        #expect(try tokenFiles().isEmpty)
    }

    @Test func aFailedLaunchReportsItsReasonAndLeavesNoTokenFile() async throws {
        let launcher = FakeServeWebLauncher(failure: .exitedBeforeReady)
        let service = service(launcher)
        await #expect(throws: VSCodeServeWebError.exitedBeforeReady) { try await service.url(vscode: Self.vscode) }
        #expect(try tokenFiles().isEmpty)
    }

    @Test func anInstallWithoutAServeWebCLIIsRefusedWithoutALaunch() async throws {
        let launcher = FakeServeWebLauncher()
        let service = VSCodeServeWebService(
            planner: VSCodeServeWebLaunchPlanner(homeDirectory: root, environment: [:], isExecutable: { _ in false },
                                                 data: { _ in nil }, contents: { _ in [] }, modificationDate: { _ in nil },
                                                 executableTrust: { _ in true }),
            launcher: launcher, tokenDirectory: root
        )
        await #expect(throws: VSCodeServeWebError.serverMissing) { try await service.url(vscode: Self.vscode) }
        #expect(await launcher.launches.isEmpty)
        #expect(try tokenFiles().isEmpty)
    }

    @Test func appExitEndsTheServerSynchronously() async throws {
        let launcher = FakeServeWebLauncher()
        let service = service(launcher)
        _ = try await service.url(vscode: Self.vscode)
        service.terminateForAppExit()
        #expect(await launcher.processes.allSatisfy { !$0.isRunning })
    }
}
