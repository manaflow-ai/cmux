import CmuxTerminalCore
import Foundation
import Testing
@testable import CmuxTerminal

@MainActor
struct TerminalSurfaceLaunchResolverTests {
    @Test func customCommandAndEmbeddedLaunchShareOneResolvedEnvironment() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        var template = CmuxSurfaceConfigTemplate()
        template.workingDirectory = "/template"
        template.command = "echo template"
        template.environmentVariables = [
            "TERM": "bad-term",
            "BASE": "base",
            "PATH": "/usr/bin",
        ]
        template.initialInput = "template-input"
        let resolver = makeResolver(defaultArguments: ["/bin/test-shell", "-l"])

        let resolved = resolver.resolve(
            TerminalSurfaceLaunchRequest(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                configTemplate: template,
                workingDirectory: "/request",
                portOrdinal: 3,
                initialCommand: "printf '%s' '$HOME'",
                initialInput: "request-input",
                runtimeInitialInput: "runtime-input",
                initialEnvironmentOverrides: [
                    "TERM": "still-bad",
                    "OVERRIDE": "override",
                ],
                additionalEnvironment: [
                    "BASE": "additional",
                    "ADDED": "added",
                ]
            ),
            commandShims: nil
        )

        #expect(resolved.workingDirectory == "/request")
        #expect(resolved.command == "printf '%s' '$HOME'")
        #expect(resolved.arguments == nil)
        #expect(resolved.initialInput == "runtime-inputrequest-input")
        #expect(resolved.environment["TERM"] == "xterm-256color")
        #expect(resolved.environment["BASE"] == "additional")
        #expect(resolved.environment["OVERRIDE"] == "override")
        #expect(resolved.environment["ADDED"] == "added")
        #expect(resolved.environment["CMUX_WORKSPACE_ID"] == workspaceID.uuidString)
        #expect(resolved.environment["CMUX_SURFACE_ID"] == surfaceID.uuidString)
        #expect(resolved.environment["CMUX_TERMINAL_LIFECYCLE_ID"] == surfaceID.uuidString)
        #expect(resolved.environment["CMUX_SOCKET_PATH"] == "/tmp/cmux-test.sock")
        #expect(resolved.environment["CMUX_PORT"] == "40300")
        #expect(resolved.environment["CMUX_PORT_END"] == "40399")
        #expect(resolved.environment["CMUX_PORT_RANGE"] == "100")
    }

    @Test func defaultShellUsesExplicitLoginArgumentsAndNoCommand() {
        let resolver = makeResolver(defaultArguments: ["/usr/bin/login", "-flp", "tester"])
        let resolved = resolver.resolve(
            TerminalSurfaceLaunchRequest(
                workspaceID: UUID(),
                surfaceID: UUID(),
                configTemplate: nil,
                workingDirectory: nil,
                portOrdinal: 0,
                initialCommand: nil,
                initialInput: nil,
                initialEnvironmentOverrides: [:],
                additionalEnvironment: [:]
            ),
            commandShims: nil
        )

        #expect(resolved.command == nil)
        #expect(resolved.arguments == ["/usr/bin/login", "-flp", "tester"])
    }

    @Test func resolvedGhosttyShellIsProtectedFromLaunchOverrides() {
        var template = CmuxSurfaceConfigTemplate()
        template.environmentVariables = ["SHELL": "/bin/bash"]
        let resolver = makeResolver(
            defaultArguments: ["/opt/homebrew/bin/fish", "-l"],
            resolvedUserShell: "/opt/homebrew/bin/fish"
        )

        let resolved = resolver.resolve(
            TerminalSurfaceLaunchRequest(
                workspaceID: UUID(),
                surfaceID: UUID(),
                configTemplate: template,
                workingDirectory: nil,
                portOrdinal: 0,
                initialCommand: nil,
                initialInput: nil,
                initialEnvironmentOverrides: ["SHELL": "/bin/zsh"],
                additionalEnvironment: ["SHELL": "/usr/local/bin/nu"]
            ),
            commandShims: nil
        )

        #expect(resolved.environment["SHELL"] == "/opt/homebrew/bin/fish")
    }

    @Test func userGhosttyCommandOutranksResolvedShellFallback() {
        let resolver = makeResolver(
            defaultArguments: ["/usr/bin/login", "-flp", "tester"],
            resolvedUserShell: "/opt/homebrew/bin/fish",
            userGhosttyCommand: "direct: /usr/local/bin/nu --login"
        )

        let resolved = resolver.resolve(
            TerminalSurfaceLaunchRequest(
                workspaceID: UUID(),
                surfaceID: UUID(),
                configTemplate: nil,
                workingDirectory: nil,
                portOrdinal: 0,
                initialCommand: nil,
                initialInput: nil,
                initialEnvironmentOverrides: [:],
                additionalEnvironment: [:]
            ),
            commandShims: nil
        )

        #expect(resolved.command == nil)
        #expect(resolved.arguments == ["/usr/local/bin/nu", "--login"])
        #expect(resolved.environment["SHELL"] == "/opt/homebrew/bin/fish")
    }

    @Test func emptyDefaultArgumentsUseSafeFallbackLaunchForm() {
        let resolver = makeResolver(defaultArguments: [])
        let resolved = resolver.resolve(
            TerminalSurfaceLaunchRequest(
                workspaceID: UUID(),
                surfaceID: UUID(),
                configTemplate: nil,
                workingDirectory: nil,
                portOrdinal: 0,
                initialCommand: nil,
                initialInput: nil,
                initialEnvironmentOverrides: [:],
                additionalEnvironment: [:]
            ),
            commandShims: nil
        )

        #expect(resolved.command == nil)
        #expect(resolved.arguments == ["/bin/zsh", "-l"])
    }

    @Test(.timeLimit(.minutes(1)))
    func commandShimInstallUsesInjectedFiveSecondDeadline() async throws {
        let clock = LaunchResolverManualClock()
        let installer = BlockingCommandShimInstaller()
        let filesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
            installAgentCommandShims: { _, _, _ in
                await installer.install()
            },
            isExecutableFile: { _ in false }
        )
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh", "-l"],
            runtimeFilesystem: filesystem,
            resourceURL: URL(fileURLWithPath: "/tmp/cmux-test-resources"),
            agentCommandShimInstallDeadline: .seconds(5),
            agentCommandShimInstallDeadlineClock: clock
        )
        let request = TerminalSurfaceLaunchRequest(
            workspaceID: UUID(),
            surfaceID: UUID(),
            configTemplate: nil,
            workingDirectory: nil,
            portOrdinal: 0,
            initialCommand: nil,
            initialInput: nil,
            initialEnvironmentOverrides: [:],
            additionalEnvironment: [:]
        )
        let resolution = Task { await resolver.resolveInstallingCommandShim(request) }
        await installer.waitUntilBlocked()
        try await clock.waitUntilSleepers()

        clock.advance(by: .seconds(5))
        let resolved = await resolution.value

        #expect(resolved.environment["CMUX_AGENT_COMMAND_SHIM_ROOT"] == nil)
        #expect(resolved.command == nil)
        await installer.waitUntilCancelled()
        #expect(await installer.cancellationCount == 1)
        #expect(await installer.isBlocked)

        let secondResolution = Task { await resolver.resolveInstallingCommandShim(request) }
        try await clock.waitUntilSleepers()
        let secondResolved = await secondResolution.value
        #expect(await installer.invocationCount == 1)
        #expect(await installer.isBlocked)
        #expect(secondResolved.environment["CMUX_AGENT_COMMAND_SHIM_ROOT"] == nil)

        await installer.complete()
        let thirdResolution = Task { await resolver.resolveInstallingCommandShim(request) }
        await installer.waitUntilBlocked()
        #expect(await installer.invocationCount == 2)
        await installer.complete()
        let thirdResolved = await thirdResolution.value
        #expect(thirdResolved.environment["CMUX_AGENT_COMMAND_SHIM_ROOT"] == nil)
    }

    private func makeResolver(
        defaultArguments: [String],
        resolvedUserShell: String? = nil,
        userGhosttyCommand: String? = nil,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem? = nil,
        resourceURL: URL? = nil,
        agentCommandShimInstallDeadline: Duration = .seconds(5),
        agentCommandShimInstallDeadlineClock: any Clock<Duration> = ContinuousClock()
    ) -> TerminalSurfaceLaunchResolver {
        TerminalSurfaceLaunchResolver(
            userGhosttyShellIntegrationMode: { "none" },
            resolvedUserShell: { resolvedUserShell },
            userGhosttyCommand: {
                userGhosttyCommand.flatMap(GhosttyConfiguredCommand.init(rawValue:))
            },
            spawnPolicyProvider: FakeSpawnPolicyProvider(),
            runtimeFilesystem: runtimeFilesystem ?? TerminalSurfaceRuntimeFilesystem(
                agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
                installAgentCommandShims: { _, _, _ in nil },
                isExecutableFile: { _ in false }
            ),
            sessionPortBase: 40_000,
            sessionPortRangeSize: 100,
            resourceURL: resourceURL,
            bundleIdentifier: "com.cmux.test",
            ambientEnvironment: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"],
            defaultShellArguments: { defaultArguments },
            agentCommandShimInstallDeadline: agentCommandShimInstallDeadline,
            agentCommandShimInstallDeadlineClock: agentCommandShimInstallDeadlineClock
        )
    }
}

private actor BlockingCommandShimInstaller {
    private var blockWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<TerminalSurfaceAgentCommandShimSet?, Never>?
    private(set) var cancellationCount = 0
    private(set) var invocationCount = 0
    var isBlocked: Bool { completion != nil }

    func install() async -> TerminalSurfaceAgentCommandShimSet? {
        invocationCount += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
                let waiters = blockWaiters
                blockWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            Task { await self.cancelInstall() }
        }
    }

    func waitUntilBlocked() async {
        guard completion == nil else { return }
        await withCheckedContinuation { continuation in
            blockWaiters.append(continuation)
        }
    }

    func waitUntilCancelled() async {
        guard cancellationCount == 0 else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    private func cancelInstall() {
        cancellationCount += 1
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func complete() {
        completion?.resume(returning: nil)
        completion = nil
    }
}

private final class LaunchResolverManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []
    private var parkWaiters: [
        UUID: (count: Int, continuation: CheckedContinuation<Void, any Error>)
    ] = [:]

    var now: Instant {
        lock.withLock { currentInstant }
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledSleeperIDs.remove(identifier) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= currentInstant {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[identifier] = Sleeper(
                    deadline: deadline,
                    continuation: continuation
                )
                let waiters = takeSatisfiedParkWaitersLocked()
                lock.unlock()
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: identifier)
            if sleeper == nil { cancelledSleeperIDs.insert(identifier) }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitUntilSleepers(count: Int = 1) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if sleepers.count >= count {
                    lock.unlock()
                    continuation.resume()
                } else {
                    parkWaiters[identifier] = (count, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = parkWaiters.removeValue(forKey: identifier)
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        var due: [Sleeper] = []
        for (identifier, sleeper) in sleepers where sleeper.deadline <= currentInstant {
            sleepers[identifier] = nil
            due.append(sleeper)
        }
        lock.unlock()
        for sleeper in due.sorted(by: { $0.deadline < $1.deadline }) {
            sleeper.continuation.resume()
        }
    }

    private func takeSatisfiedParkWaitersLocked() -> [CheckedContinuation<Void, any Error>] {
        let identifiers = parkWaiters.compactMap { identifier, waiter in
            sleepers.count >= waiter.count ? identifier : nil
        }
        return identifiers.compactMap {
            parkWaiters.removeValue(forKey: $0)?.continuation
        }
    }
}
