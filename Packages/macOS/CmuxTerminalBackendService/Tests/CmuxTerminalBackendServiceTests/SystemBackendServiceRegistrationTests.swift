@testable import CmuxTerminalBackendService
import Darwin
import Foundation
import Testing

@Suite("Version-pinned launchd registration", .serialized)
struct SystemBackendServiceRegistrationTests {
    @Test("launchctl runner bounds a wedged exact child")
    func boundedCommandRunnerTimesOut() throws {
        let runner = BoundedBackendServiceCommandRunner()
        let arguments = ["/usr/bin/tail", "-f", "/dev/null"]

        do {
            _ = try runner.run(
                executableURL: URL(fileURLWithPath: arguments[0]),
                arguments: Array(arguments.dropFirst()),
                timeout: 0.05
            )
            Issue.record("expected bounded command timeout")
        } catch let error as BackendServicePairError {
            #expect(error == .launchControlTimedOut(arguments: arguments))
        }
    }

    @Test("launchctl runner drains output without pipe backpressure")
    func commandOutputCannotDeadlock() throws {
        let result = try BoundedBackendServiceCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "dd if=/dev/zero bs=65536 count=2 2>/dev/null"],
            timeout: 2
        )

        #expect(result.status == 0)
        #expect(result.output.utf8.count == 131_072)
    }

    @Test("launchctl output file is private from creation")
    func commandOutputFileUsesPrivateMode() throws {
        let result = try BoundedBackendServiceCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/stat -f %Lp /dev/fd/1 >&2"],
            timeout: 2
        )

        #expect(result.status == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "600")
    }

    @Test("launchctl timeout propagates through the injected command seam")
    func launchControllerPropagatesTypedTimeout() throws {
        let controller = SystemBackendServiceLaunchController(
            userID: 501,
            commandRunner: TimingOutCommandRunner()
        )
        let arguments = [
            "/bin/launchctl",
            "print",
            "gui/501/com.cmuxterm.app.terminal-backend",
        ]

        #expect(throws: BackendServicePairError.launchControlTimedOut(arguments: arguments)) {
            _ = try controller.status(
                label: "com.cmuxterm.app.terminal-backend",
                propertyListURL: URL(fileURLWithPath: "/unused")
            )
        }
    }

    @Test("preparing a new pair never collects another staged version")
    func preparingPairDoesNotCollectConcurrentStaging() async throws {
        let installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-concurrent-staging-\(UUID())", isDirectory: true)
        let controller = FakeLaunchController()
        let first = try PairFixture(buildID: buildID("2"), installationRoot: installRoot)
        let second = try PairFixture(buildID: buildID("3"), installationRoot: installRoot)
        let registration1 = SystemBackendServiceRegistration(
            descriptor: .production,
            installer: first.installer,
            propertyListURL: installRoot.appendingPathComponent("service.plist"),
            launchController: controller
        )
        let registration2 = SystemBackendServiceRegistration(
            descriptor: .production,
            installer: second.installer,
            propertyListURL: installRoot.appendingPathComponent("service.plist"),
            launchController: controller
        )

        let pair1 = try await registration1.prepareBundledPair()
        let pair2 = try await registration2.prepareBundledPair()

        #expect(FileManager.default.fileExists(atPath: pair1.backendExecutableURL.path))
        #expect(FileManager.default.fileExists(atPath: pair2.backendExecutableURL.path))
    }

    @Test("loaded descriptor survives restart throttle with no running PID")
    func loadedDescriptorProtectsVersionWithoutProcess() async throws {
        let installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-throttled-registration-\(UUID())", isDirectory: true)
        let launchAgent = installRoot.appendingPathComponent("service.plist")
        let controller = FakeLaunchController()
        let v1 = try PairFixture(buildID: buildID("a"), installationRoot: installRoot)
        let v2 = try PairFixture(buildID: buildID("b"), installationRoot: installRoot)
        let registration1 = SystemBackendServiceRegistration(
            descriptor: .production,
            installer: v1.installer,
            propertyListURL: launchAgent,
            launchController: controller
        )
        let registration2 = SystemBackendServiceRegistration(
            descriptor: .production,
            installer: v2.installer,
            propertyListURL: launchAgent,
            launchController: controller
        )
        let pair1 = try await registration1.prepareBundledPair()
        try await registration1.register(pair1)

        let attributes = try FileManager.default.attributesOfItem(atPath: launchAgent.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.uint16Value & 0o777 == 0o600)
        let payload = try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: launchAgent),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        #expect(payload["Program"] as? String == pair1.backendExecutableURL.path)
        #expect(payload["CMUXBackendBuildID"] == nil)
        #expect(payload["CMUXImmutableVersionedPairRequired"] == nil)

        // The fake controller has a loaded descriptor but intentionally no PID census.
        _ = try await registration2.prepareBundledPair()
        #expect(FileManager.default.fileExists(atPath: pair1.backendExecutableURL.path))
        #expect(FileManager.default.fileExists(atPath: pair1.rendererExecutableURL.path))
        controller.simulateLaunchdRestart()
        #expect(controller.loadedProgram == pair1.backendExecutableURL)
        #expect(controller.rendererRestartPath() == pair1.rendererExecutableURL)
    }

    @Test("app replacement stages vN+1 while live vN keeps its renderer sibling")
    func liveVersionIsNeverReplaced() async throws {
        let installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registration-\(UUID())", isDirectory: true)
        let launchAgent = installRoot.appendingPathComponent("service.plist")
        let controller = FakeLaunchController()
        let v1 = try PairFixture(buildID: buildID("c"), rendererContents: "renderer-v1", installationRoot: installRoot)
        let v2 = try PairFixture(buildID: buildID("d"), rendererContents: "renderer-v2", installationRoot: installRoot)
        let registration1 = SystemBackendServiceRegistration(
            descriptor: .production,
            installer: v1.installer,
            propertyListURL: launchAgent,
            launchController: controller
        )
        let registration2 = SystemBackendServiceRegistration(
            descriptor: .production,
            installer: v2.installer,
            propertyListURL: launchAgent,
            launchController: controller
        )
        let pair1 = try await registration1.prepareBundledPair()
        try await registration1.register(pair1)
        let pair2 = try await registration2.prepareBundledPair()

        let activation = try await registration2.activateIfServiceStopped(pair2)
        #expect(activation == .deferred(active: pair1))
        #expect(controller.bootoutCount == 0)
        #expect(controller.loadedProgram == pair1.backendExecutableURL)

        // A renderer death is handled by the still-running daemon's immutable sibling lookup.
        let restartedRenderer = try #require(controller.rendererRestartPath())
        #expect(restartedRenderer == pair1.rendererExecutableURL)
        #expect(try String(contentsOf: restartedRenderer, encoding: .utf8) == "renderer-v1")
        #expect(try String(contentsOf: pair2.rendererExecutableURL, encoding: .utf8) == "renderer-v2")
    }

    @Test("safe stopped handoff loads vN+1 and subsequent restart remains pinned")
    func stoppedHandoffUsesNewVersion() async throws {
        let installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-handoff-\(UUID())", isDirectory: true)
        let launchAgent = installRoot.appendingPathComponent("service.plist")
        let controller = FakeLaunchController()
        let v1 = try PairFixture(buildID: buildID("e"), installationRoot: installRoot)
        let v2 = try PairFixture(buildID: buildID("f"), installationRoot: installRoot)
        let registration1 = SystemBackendServiceRegistration(
            descriptor: .production,
            installer: v1.installer,
            propertyListURL: launchAgent,
            launchController: controller
        )
        let registration2 = SystemBackendServiceRegistration(
            descriptor: .production,
            installer: v2.installer,
            propertyListURL: launchAgent,
            launchController: controller
        )
        let pair1 = try await registration1.prepareBundledPair()
        try await registration1.register(pair1)
        let pair2 = try await registration2.prepareBundledPair()

        controller.simulateExplicitSafeStop()
        #expect(
            try await registration2.activateIfServiceStopped(pair2)
                == .activated(pair2)
        )
        #expect(controller.loadedProgram == pair2.backendExecutableURL)
        controller.simulateLaunchdRestart()
        #expect(controller.loadedProgram == pair2.backendExecutableURL)
        #expect(controller.bootstrapCount == 3)
    }

    @Test("tampered installed helper never reaches launchctl")
    func tamperedRendererFailsBeforeBootstrap() async throws {
        let fixture = try PairFixture(buildID: buildID("1"))
        let controller = FakeLaunchController()
        let registration = SystemBackendServiceRegistration(
            descriptor: .production,
            installer: fixture.installer,
            propertyListURL: fixture.root.appendingPathComponent("service.plist"),
            launchController: controller
        )
        let pair = try await registration.prepareBundledPair()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: pair.rendererExecutableURL.path
        )
        try Data("tampered".utf8).write(to: pair.rendererExecutableURL)

        await #expect(throws: BackendServicePairError.self) {
            try await registration.register(pair)
        }
        #expect(controller.bootstrapCount == 0)
        #expect(controller.loadedProgram == nil)
    }

    private func buildID(_ nibble: Character) -> String {
        String(repeating: String(nibble), count: 64)
    }
}

private struct TimingOutCommandRunner: BackendServiceCommandRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout _: TimeInterval
    ) throws -> BackendServiceCommandResult {
        throw BackendServicePairError.launchControlTimedOut(
            arguments: [executableURL.path] + arguments
        )
    }
}

private final class FakeLaunchController: BackendServiceLaunchControlling, @unchecked Sendable {
    var loadedProgram: URL?
    var lastBootstrappedPropertyList: URL?
    var bootstrapCount = 0
    var bootoutCount = 0

    func status(label _: String, propertyListURL _: URL) -> BackendServiceStatus {
        loadedProgram == nil ? .notRegistered : .enabled
    }

    func loadedProgramURL(label _: String) -> URL? { loadedProgram }

    func bootstrap(propertyListURL: URL) throws {
        let payload = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: propertyListURL),
            options: [],
            format: nil
        ) as? [String: Any]
        let program = try #require(payload?["Program"] as? String)
        loadedProgram = URL(fileURLWithPath: program)
        lastBootstrappedPropertyList = propertyListURL
        bootstrapCount += 1
    }

    func bootout(label _: String) {
        bootoutCount += 1
        loadedProgram = nil
    }

    func rendererRestartPath() -> URL? {
        loadedProgram?.deletingLastPathComponent()
            .appendingPathComponent("cmux-terminal-renderer")
    }

    func simulateExplicitSafeStop() {
        loadedProgram = nil
    }

    func simulateLaunchdRestart() {
        guard let lastBootstrappedPropertyList,
              let payload = try? PropertyListSerialization.propertyList(
                  from: Data(contentsOf: lastBootstrappedPropertyList),
                  options: [],
                  format: nil
              ) as? [String: Any],
              let program = payload["Program"] as? String
        else { return }
        loadedProgram = URL(fileURLWithPath: program)
        bootstrapCount += 1
    }
}
