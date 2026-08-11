import CmuxTerminalCore
import Dispatch
import Foundation
import os
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
            commandShims: nil,
            launchResourceSnapshot: .unavailable
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

    @Test func invalidSessionPortRangeCannotPublishInvalidOrOverriddenPorts() {
        var template = CmuxSurfaceConfigTemplate()
        template.environmentVariables = [
            "CMUX_PORT": "template-port",
            "CMUX_PORT_END": "template-end",
            "CMUX_PORT_RANGE": "template-range",
        ]
        let resolver = makeResolver(defaultArguments: ["/bin/zsh"], sessionPortBase: 65_535)

        let resolved = resolver.resolve(
            TerminalSurfaceLaunchRequest(
                workspaceID: UUID(),
                surfaceID: UUID(),
                configTemplate: template,
                workingDirectory: nil,
                portOrdinal: 1,
                initialCommand: nil,
                initialInput: nil,
                initialEnvironmentOverrides: ["CMUX_PORT": "override-port"],
                additionalEnvironment: ["CMUX_PORT_END": "additional-end"]
            ),
            commandShims: nil,
            launchResourceSnapshot: .unavailable
        )

        #expect(resolved.environment["CMUX_PORT"] == nil)
        #expect(resolved.environment["CMUX_PORT_END"] == nil)
        #expect(resolved.environment["CMUX_PORT_RANGE"] == nil)
    }

    @Test func overflowingSessionPortCalculationDoesNotTerminate() {
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh"],
            sessionPortBase: Int.max,
            sessionPortRangeSize: Int.max
        )

        let resolved = resolver.resolve(
            TerminalSurfaceLaunchRequest(
                workspaceID: UUID(),
                surfaceID: UUID(),
                configTemplate: nil,
                workingDirectory: nil,
                portOrdinal: Int.max,
                initialCommand: nil,
                initialInput: nil,
                initialEnvironmentOverrides: [:],
                additionalEnvironment: [:]
            ),
            commandShims: nil,
            launchResourceSnapshot: .unavailable
        )

        #expect(resolved.environment["CMUX_PORT"] == nil)
        #expect(resolved.environment["CMUX_PORT_END"] == nil)
        #expect(resolved.environment["CMUX_PORT_RANGE"] == nil)
    }

    @Test func nonpositiveCommandShimRemovalAttemptLimitUsesOneSafeAttempt() {
        let filesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
            installAgentCommandShims: { _, _, _ in nil },
            removeAgentCommandShims: { _ in },
            agentCommandShimRemovalAttemptLimit: 0,
            isExecutableFile: { _ in false },
            directoryExists: { _ in false }
        )

        #expect(filesystem.agentCommandShimRemovalAttemptLimit == 1)
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
            commandShims: nil,
            launchResourceSnapshot: .unavailable
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
            commandShims: nil,
            launchResourceSnapshot: .unavailable
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
            commandShims: nil,
            launchResourceSnapshot: .unavailable
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
            commandShims: nil,
            launchResourceSnapshot: .unavailable
        )

        #expect(resolved.command == nil)
        #expect(resolved.arguments == ["/bin/zsh", "-l"])
    }

    @Test func fixedBundleResourceChecksRunOffMainActorOncePerResolver() async {
        let recorder = LaunchResourceFileCheckRecorder()
        let filesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
            installAgentCommandShims: { _, _, _ in nil },
            removeAgentCommandShims: { _ in },
            isExecutableFile: { recorder.record(path: $0) },
            directoryExists: { _ in true }
        )
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh", "-l"],
            runtimeFilesystem: filesystem,
            resourceURL: URL(fileURLWithPath: "/tmp/cmux-test-resources")
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

        let firstResolved = (await resolver.resolveInstallingCommandShim(request)).resolvedLaunch
        let secondResolved = (await resolver.resolveInstallingCommandShim(request)).resolvedLaunch

        #expect(recorder.paths == [
            "/tmp/cmux-test-resources/bin/cmux",
            "/tmp/cmux-test-resources/bin/ghostty",
        ])
        #expect(!recorder.checkedOnMainThread)
        #expect(
            firstResolved.environment["CMUX_BUNDLED_CLI_PATH"]
                == "/tmp/cmux-test-resources/bin/cmux"
        )
        #expect(firstResolved.environment["GHOSTTY_BIN"] == "/tmp/cmux-test-resources/bin/ghostty")
        #expect(firstResolved.environment["PATH"] == "/tmp/cmux-test-resources/bin:/usr/bin")
        #expect(secondResolved.environment == firstResolved.environment)
    }

    @Test func asyncLaunchCachesDefaultShellArgumentsOffMainActor() async {
        let recorder = DefaultShellArgumentsRecorder()
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh", "-l"],
            defaultArgumentsProvider: {
                recorder.resolve()
            }
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

        _ = await resolver.resolveInstallingCommandShim(request)
        _ = await resolver.resolveInstallingCommandShim(request)

        #expect(recorder.invocationCount == 1)
        #expect(!recorder.resolvedOnMainThread)
    }

    @Test func synchronousLaunchUsesOnlyItsFixedDefaultArguments() async {
        let recorder = DefaultShellArgumentsRecorder()
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh", "-l"],
            defaultArgumentsProvider: {
                recorder.resolve()
            }
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

        let synchronous = resolver.resolve(
            request,
            commandShims: nil,
            launchResourceSnapshot: .unavailable
        )
        let asynchronous = (
            await resolver.resolveInstallingCommandShim(request)
        ).resolvedLaunch

        #expect(synchronous.arguments == ["/bin/zsh", "-l"])
        #expect(asynchronous.arguments == ["/usr/bin/login", "-flp", "tester"])
        #expect(recorder.invocationCount == 1)
        #expect(!recorder.resolvedOnMainThread)
    }

    @Test(.timeLimit(.minutes(1)))
    func launchResourceWaitersShareOneProviderDeadline() async throws {
        let state = TerminalSurfaceLaunchResourceProviderState()
        let clock = LaunchResolverManualClock()
        let first = Task {
            await state.value(
                identifier: UUID(),
                deadline: .seconds(5),
                clock: clock
            )
        }
        while await state.pendingWaiterCount < 1 { await Task.yield() }
        let second = Task {
            await state.value(
                identifier: UUID(),
                deadline: .seconds(5),
                clock: clock
            )
        }
        while await state.pendingWaiterCount < 2 { await Task.yield() }

        #expect(await state.pendingDeadlineCount == 1)
        clock.advance(by: .seconds(5))
        #expect(await first.value == .unavailable)
        #expect(await second.value == .unavailable)
    }

    @Test(.timeLimit(.minutes(1)))
    func defaultShellWaitersShareOneProviderDeadline() async throws {
        let state = TerminalSurfaceDefaultShellArgumentsState()
        let clock = LaunchResolverManualClock()
        let fallback = ["/bin/zsh", "-l"]
        let first = Task {
            await state.value(
                identifier: UUID(),
                fallback: fallback,
                deadline: .seconds(5),
                clock: clock
            )
        }
        while await state.pendingWaiterCount < 1 { await Task.yield() }
        let second = Task {
            await state.value(
                identifier: UUID(),
                fallback: fallback,
                deadline: .seconds(5),
                clock: clock
            )
        }
        while await state.pendingWaiterCount < 2 { await Task.yield() }

        #expect(await state.pendingDeadlineCount == 1)
        clock.advance(by: .seconds(5))
        #expect(await first.value == fallback)
        #expect(await second.value == fallback)
    }

    @Test(.timeLimit(.minutes(1)))
    func hungLaunchResourceCheckUsesInjectedDeadlineFallback() async throws {
        let blocker = DispatchSemaphore(value: 0)
        defer { blocker.signal() }
        let clock = LaunchResolverManualClock()
        let filesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
            installAgentCommandShims: { _, _, _ in nil },
            removeAgentCommandShims: { _ in },
            isExecutableFile: { _ in false },
            directoryExists: { _ in
                blocker.wait()
                return true
            }
        )
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh", "-l"],
            runtimeFilesystem: filesystem,
            resourceURL: URL(fileURLWithPath: "/tmp/cmux-test-resources"),
            launchResourceSnapshotDeadline: .seconds(5),
            launchResourceSnapshotDeadlineClock: clock
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
        let firstResolution = Task {
            await resolver.resolveInstallingCommandShim(request)
        }
        try await clock.waitUntilSleepers()

        clock.advance(by: .seconds(5))
        let firstResolved = await firstResolution.value.resolvedLaunch
        let secondResolved = (
            await resolver.resolveInstallingCommandShim(request)
        ).resolvedLaunch

        #expect(firstResolved.environment["CMUX_BUNDLED_CLI_PATH"] == nil)
        #expect(firstResolved.environment["GHOSTTY_BIN"] == nil)
        #expect(secondResolved.environment == firstResolved.environment)
    }

    @Test(.timeLimit(.minutes(1)))
    func hungDefaultShellLookupUsesInjectedDeadlineFallback() async throws {
        let blocker = DispatchSemaphore(value: 0)
        defer { blocker.signal() }
        let clock = LaunchResolverManualClock()
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh", "-l"],
            defaultArgumentsProvider: {
                blocker.wait()
                return ["/usr/bin/login", "-flp", "tester"]
            },
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
        let resolution = Task {
            await resolver.resolveInstallingCommandShim(request)
        }
        try await clock.waitUntilSleepers()

        clock.advance(by: .seconds(5))
        let resolved = await resolution.value.resolvedLaunch

        #expect(resolved.arguments == ["/bin/zsh", "-l"])
    }

    @Test(.timeLimit(.minutes(1)))
    func hungDefaultShellLookupCachesDeadlineFallback() async throws {
        let blocker = DispatchSemaphore(value: 0)
        defer { blocker.signal() }
        let clock = LaunchResolverManualClock()
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh", "-l"],
            defaultArgumentsProvider: {
                blocker.wait()
                return ["/usr/bin/login", "-flp", "tester"]
            },
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
        let firstResolution = Task {
            await resolver.resolveInstallingCommandShim(request)
        }
        try await clock.waitUntilSleepers()
        clock.advance(by: .seconds(5))
        let firstResolved = await firstResolution.value.resolvedLaunch

        let secondResolved = (
            await resolver.resolveInstallingCommandShim(request)
        ).resolvedLaunch

        #expect(firstResolved.arguments == ["/bin/zsh", "-l"])
        #expect(secondResolved.arguments == ["/bin/zsh", "-l"])
    }

    @Test(.timeLimit(.minutes(1)))
    func commandShimInstallUsesInjectedFiveSecondDeadline() async throws {
        let clock = LaunchResolverManualClock()
        let installer = BlockingCommandShimInstaller()
        let cleanupRecorder = CommandShimCleanupRecorder()
        let filesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
            installAgentCommandShims: { _, _, _ in
                await installer.install()
            },
            removeAgentCommandShims: { shims in
                await cleanupRecorder.record(shims)
            },
            isExecutableFile: { _ in false },
            directoryExists: { _ in false }
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
        let resolved = await resolution.value.resolvedLaunch

        #expect(resolved.environment["CMUX_AGENT_COMMAND_SHIM_ROOT"] == nil)
        #expect(resolved.command == nil)
        await installer.waitUntilCancelled()
        #expect(await installer.cancellationCount == 1)
        #expect(await installer.isBlocked)

        let secondResolution = Task { await resolver.resolveInstallingCommandShim(request) }
        try await clock.waitUntilSleepers()
        let secondResolved = await secondResolution.value.resolvedLaunch
        #expect(await installer.invocationCount == 1)
        #expect(await installer.isBlocked)
        #expect(secondResolved.environment["CMUX_AGENT_COMMAND_SHIM_ROOT"] == nil)

        let lateShims = TerminalSurfaceAgentCommandShimSet(
            directoryPath: "/tmp/late-command-shims",
            shims: []
        )
        await installer.complete(with: lateShims)
        #expect(await cleanupRecorder.next() == lateShims)
        let thirdResolution = Task { await resolver.resolveInstallingCommandShim(request) }
        await installer.waitUntilBlocked()
        #expect(await installer.invocationCount == 2)
        await installer.complete()
        let thirdResolved = await thirdResolution.value.resolvedLaunch
        #expect(thirdResolved.environment["CMUX_AGENT_COMMAND_SHIM_ROOT"] == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func canceledLaunchReleasesNewShimsBeforeOwnershipTransfer() async throws {
        let clock = LaunchResolverManualClock()
        let installer = BlockingCommandShimInstaller()
        let cleanupRecorder = CommandShimCleanupRecorder()
        let shellBlocker = DispatchSemaphore(value: 0)
        defer { shellBlocker.signal() }
        let shims = TerminalSurfaceAgentCommandShimSet(
            directoryPath: "/tmp/canceled-command-shims",
            shims: []
        )
        let filesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
            installAgentCommandShims: { _, _, _ in
                await installer.install()
            },
            removeAgentCommandShims: { shims in
                await cleanupRecorder.record(shims)
            },
            isExecutableFile: { _ in false },
            directoryExists: { _ in false }
        )
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh", "-l"],
            defaultArgumentsProvider: {
                shellBlocker.wait()
                return ["/bin/zsh", "-l"]
            },
            runtimeFilesystem: filesystem,
            resourceURL: URL(fileURLWithPath: "/tmp/cmux-test-resources"),
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
        await installer.complete(with: shims)
        while clock.sleepInvocationCount < 2 { await Task.yield() }

        resolution.cancel()
        let canceled = await resolution.value

        #expect(canceled.takeCommandShimLease() == nil)
        #expect(canceled.resolvedLaunch.environment["CMUX_AGENT_COMMAND_SHIM_ROOT"] == nil)
        #expect(await cleanupRecorder.next() == shims)
    }

    @Test
    func completedCommandShimInstallTransfersOneOwnedLease() async throws {
        let cleanupRecorder = CommandShimCleanupRecorder()
        let shims = TerminalSurfaceAgentCommandShimSet(
            directoryPath: "/tmp/owned-command-shims",
            shims: []
        )
        let filesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
            installAgentCommandShims: { _, _, _ in shims },
            removeAgentCommandShims: { shims in
                await cleanupRecorder.record(shims)
            },
            isExecutableFile: { _ in false },
            directoryExists: { _ in false }
        )
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh", "-l"],
            runtimeFilesystem: filesystem,
            resourceURL: URL(fileURLWithPath: "/tmp/cmux-test-resources")
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

        let ownedLaunch = await resolver.resolveInstallingCommandShim(request)
        let lease = try #require(ownedLaunch.takeCommandShimLease())

        #expect(lease.shims == shims)
        #expect(ownedLaunch.resolvedLaunch.environment["CMUX_AGENT_COMMAND_SHIM_ROOT"] == shims.directoryPath)
        #expect(await lease.release())
        #expect(await cleanupRecorder.next() == shims)
    }

    @Test(.timeLimit(.minutes(1)))
    func lateCancellationReleasesAnUnacceptedCommandShimLease() async throws {
        let cleanupRecorder = CommandShimCleanupRecorder()
        let shims = TerminalSurfaceAgentCommandShimSet(
            directoryPath: "/tmp/unaccepted-command-shims",
            shims: []
        )
        let filesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
            installAgentCommandShims: { _, _, _ in shims },
            removeAgentCommandShims: { shims in
                await cleanupRecorder.record(shims)
            },
            isExecutableFile: { _ in false },
            directoryExists: { _ in false }
        )
        let resolver = makeResolver(
            defaultArguments: ["/bin/zsh", "-l"],
            runtimeFilesystem: filesystem,
            resourceURL: URL(fileURLWithPath: "/tmp/cmux-test-resources")
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

        let resolution = Task {
            let ownedLaunch = await resolver.resolveInstallingCommandShim(request)
            withUnsafeCurrentTask { $0?.cancel() }
            return ownedLaunch.resolvedLaunch
        }
        let resolved = await resolution.value

        #expect(resolved.environment["CMUX_AGENT_COMMAND_SHIM_ROOT"] == shims.directoryPath)
        #expect(await cleanupRecorder.next() == shims)
    }

    @Test
    func commandShimLeaseRetainsOwnershipAfterBoundedRemovalFailure() async {
        let shims = TerminalSurfaceAgentCommandShimSet(
            directoryPath: "/tmp/retained-command-shims",
            shims: []
        )
        let recorder = CommandShimRemovalRecorder(failuresBeforeSuccess: 3)
        let state = TerminalSurfaceAgentCommandShimLeaseState(
            shims: shims,
            removalAttemptLimit: 3,
            removalLane: TerminalSurfaceAgentCommandShimRemovalLane(),
            remove: { shims in
                try recorder.remove(shims)
            },
            reportRemovalFailure: { shims, errorDescription in
                recorder.recordFailure(shims, errorDescription: errorDescription)
            }
        )

        let firstReleaseSucceeded = await state.release()

        #expect(!firstReleaseSucceeded)
        #expect(recorder.attemptCount == 3)
        #expect(recorder.failureCount == 1)
        #expect(recorder.lastFailure?.0 == shims)
        #expect(recorder.lastFailure?.1.contains("attempt: 3") == true)
        #expect(await state.hasOwnedShims)

        let secondReleaseSucceeded = await state.release()

        #expect(secondReleaseSucceeded)
        #expect(recorder.attemptCount == 4)
        #expect(recorder.failureCount == 1)
        #expect(!(await state.hasOwnedShims))
    }

    @Test(.timeLimit(.minutes(1)))
    func stalledCommandShimRemovalKeepsTheProcessRemovalLaneOccupied() async throws {
        let firstShims = TerminalSurfaceAgentCommandShimSet(
            directoryPath: "/tmp/stalled-command-shims",
            shims: []
        )
        let secondShims = TerminalSurfaceAgentCommandShimSet(
            directoryPath: "/tmp/queued-command-shims",
            shims: []
        )
        let clock = LaunchResolverManualClock()
        let lane = TerminalSurfaceAgentCommandShimRemovalLane()
        let remover = NoncooperativeCommandShimRemover()
        let failures = CommandShimRemovalRecorder(failuresBeforeSuccess: 0)
        let firstState = TerminalSurfaceAgentCommandShimLeaseState(
            shims: firstShims,
            removalAttemptLimit: 1,
            removalAttemptTimeout: .seconds(5),
            removalLane: lane,
            remove: { shims in await remover.remove(shims) },
            reportRemovalFailure: { shims, errorDescription in
                failures.recordFailure(shims, errorDescription: errorDescription)
            }
        )
        let secondState = TerminalSurfaceAgentCommandShimLeaseState(
            shims: secondShims,
            removalAttemptLimit: 3,
            removalAttemptTimeout: .seconds(5),
            removalLane: lane,
            remove: { shims in await remover.remove(shims) },
            reportRemovalFailure: { shims, errorDescription in
                failures.recordFailure(shims, errorDescription: errorDescription)
            }
        )

        let firstRelease = Task { await firstState.release(removalClock: clock) }
        await remover.waitUntilBlocked()
        try await clock.waitUntilSleepers()
        clock.advance(by: .seconds(5))
        #expect(!(await firstRelease.value))

        #expect(!(await secondState.release(removalClock: clock)))
        #expect(await remover.invocationCount == 1)

        await remover.complete()
    }

    @Test
    func runtimeFilesystemsOwnIndependentCommandShimRemovalLanes() async {
        func makeFilesystem() -> TerminalSurfaceRuntimeFilesystem {
            TerminalSurfaceRuntimeFilesystem(
                agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp"),
                installAgentCommandShims: { _, _, _ in nil },
                removeAgentCommandShims: { _ in },
                isExecutableFile: { _ in false },
                directoryExists: { _ in false }
            )
        }
        let firstFilesystem = makeFilesystem()
        let secondFilesystem = makeFilesystem()

        #expect(await firstFilesystem.agentCommandShimRemovalLane.claim())
        #expect(await secondFilesystem.agentCommandShimRemovalLane.claim())

        await firstFilesystem.agentCommandShimRemovalLane.release()
        await secondFilesystem.agentCommandShimRemovalLane.release()
    }

    @Test(.timeLimit(.minutes(1)))
    func lateCommandShimCleanupRetriesThroughInjectedClock() async throws {
        let shims = TerminalSurfaceAgentCommandShimSet(
            directoryPath: "/tmp/late-command-shims",
            shims: []
        )
        let clock = LaunchResolverManualClock()
        let recorder = CommandShimRemovalRecorder(failuresBeforeSuccess: 1)
        let owner = TerminalSurfaceAgentCommandShimCleanupOwner(
            removalAttemptLimit: 1,
            removalLane: TerminalSurfaceAgentCommandShimRemovalLane(),
            retryDelays: [.seconds(5)],
            remove: { shims in
                try recorder.remove(shims)
            },
            reportRemovalFailure: { shims, errorDescription in
                recorder.recordFailure(shims, errorDescription: errorDescription)
            }
        )

        await owner.cleanup(shims, retryClock: clock)

        #expect(recorder.attemptCount == 1)
        #expect(await owner.retainedLeaseCount == 1)
        #expect(await owner.pendingRetryCount == 1)
        try await clock.waitUntilSleepers()

        clock.advance(by: .seconds(5))
        while recorder.attemptCount < 2 { await Task.yield() }
        while await owner.retainedLeaseCount > 0 { await Task.yield() }

        #expect(recorder.failureCount == 1)
        #expect(await owner.pendingRetryCount == 0)
    }

    private func makeResolver(
        defaultArguments: [String],
        defaultArgumentsProvider: (@Sendable () -> [String])? = nil,
        resolvedUserShell: String? = nil,
        userGhosttyCommand: String? = nil,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem? = nil,
        resourceURL: URL? = nil,
        launchResourceSnapshotDeadline: Duration = .seconds(5),
        launchResourceSnapshotDeadlineClock: any Clock<Duration> = ContinuousClock(),
        agentCommandShimInstallDeadline: Duration = .seconds(5),
        agentCommandShimInstallDeadlineClock: any Clock<Duration> = ContinuousClock(),
        sessionPortBase: Int = 40_000,
        sessionPortRangeSize: Int = 100
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
                removeAgentCommandShims: { _ in },
                isExecutableFile: { _ in false },
                directoryExists: { _ in false }
            ),
            sessionPortBase: sessionPortBase,
            sessionPortRangeSize: sessionPortRangeSize,
            resourceURL: resourceURL,
            bundleIdentifier: "com.cmux.test",
            ambientEnvironment: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"],
            defaultShellArguments: defaultArguments,
            asynchronousDefaultShellArguments: defaultArgumentsProvider,
            launchResourceSnapshotDeadline: launchResourceSnapshotDeadline,
            launchResourceSnapshotDeadlineClock: launchResourceSnapshotDeadlineClock,
            agentCommandShimInstallDeadline: agentCommandShimInstallDeadline,
            agentCommandShimInstallDeadlineClock: agentCommandShimInstallDeadlineClock
        )
    }
}

private final class LaunchResourceFileCheckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    private var didCheckOnMainThread = false

    var paths: [String] {
        lock.withLock { recordedPaths }
    }

    var checkedOnMainThread: Bool {
        lock.withLock { didCheckOnMainThread }
    }

    func record(path: String) -> Bool {
        lock.withLock {
            recordedPaths.append(path)
            didCheckOnMainThread = didCheckOnMainThread || Thread.isMainThread
        }
        return true
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

    func complete(with result: TerminalSurfaceAgentCommandShimSet? = nil) {
        completion?.resume(returning: result)
        completion = nil
    }
}

private actor NoncooperativeCommandShimRemover {
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?
    private(set) var invocationCount = 0

    func remove(_ shims: TerminalSurfaceAgentCommandShimSet) async {
        _ = shims
        invocationCount += 1
        await withCheckedContinuation { continuation in
            completion = continuation
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilBlocked() async {
        guard completion == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func complete() {
        completion?.resume()
        completion = nil
    }
}

actor CommandShimCleanupRecorder {
    private var recorded: [TerminalSurfaceAgentCommandShimSet] = []
    private var waiters:
        [CheckedContinuation<TerminalSurfaceAgentCommandShimSet, Never>] = []

    func record(_ shims: TerminalSurfaceAgentCommandShimSet) {
        guard waiters.isEmpty else {
            waiters.removeFirst().resume(returning: shims)
            return
        }
        recorded.append(shims)
    }

    func next() async -> TerminalSurfaceAgentCommandShimSet {
        guard recorded.isEmpty else { return recorded.removeFirst() }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct CommandShimRemovalTestError: Error {
    let attempt: Int
}

private final class CommandShimRemovalRecorder: @unchecked Sendable {
    private struct State {
        var attempts = 0
        var failuresBeforeSuccess: Int
        var failures: [(TerminalSurfaceAgentCommandShimSet, String)] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(failuresBeforeSuccess: Int) {
        state = OSAllocatedUnfairLock(
            initialState: State(failuresBeforeSuccess: failuresBeforeSuccess)
        )
    }

    var attemptCount: Int { state.withLock { $0.attempts } }
    var failureCount: Int { state.withLock { $0.failures.count } }
    var lastFailure: (TerminalSurfaceAgentCommandShimSet, String)? {
        state.withLock { $0.failures.last }
    }

    func remove(_ shims: TerminalSurfaceAgentCommandShimSet) throws {
        let failure = state.withLock { state -> CommandShimRemovalTestError? in
            state.attempts += 1
            guard state.attempts <= state.failuresBeforeSuccess else { return nil }
            return CommandShimRemovalTestError(attempt: state.attempts)
        }
        if let failure { throw failure }
    }

    func recordFailure(
        _ shims: TerminalSurfaceAgentCommandShimSet,
        errorDescription: String
    ) {
        state.withLock { $0.failures.append((shims, errorDescription)) }
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
    private var sleepInvocations = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []
    private var parkWaiters: [
        UUID: (count: Int, continuation: CheckedContinuation<Void, any Error>)
    ] = [:]

    var now: Instant {
        lock.withLock { currentInstant }
    }

    var minimumResolution: Duration { .zero }
    var sleepInvocationCount: Int { lock.withLock { sleepInvocations } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                sleepInvocations += 1
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
