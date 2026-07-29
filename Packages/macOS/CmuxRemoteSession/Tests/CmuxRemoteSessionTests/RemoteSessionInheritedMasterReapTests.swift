import CmuxCore
import CmuxFoundation
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Inherited ControlMaster reap")
struct RemoteSessionInheritedMasterReapTests {
    @Test("Owned persistent relay exits its inherited master before retrying")
    func ownedPersistentRelayExitsInheritedMaster() async throws {
        let runner = InheritedMasterReapProcessRunner()
        let launcher = RecordingReverseRelayLauncher()
        let clock = ManualBrokerClock()
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(
                runner: runner,
                reverseRelayLauncher: launcher,
                persistentDaemonSlot: "ssh-persistent-slot",
                clock: clock
            )
        let coordinator = fixture.coordinator
        defer {
            try? FileManager.default.removeItem(
                at: fixture.scratchDirectory
            )
        }
        var requests = runner.requestStream.makeAsyncIterator()

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(
                remotePath: "/tmp/cmuxd-remote"
            )
        }

        let initialRequests = runner.requests
        try #require(!initialRequests.contains(where: {
            Self.isControlCommand("cancel", in: $0.arguments)
        }))
        #expect(initialRequests.filter {
            Self.isControlCommand("forward", in: $0.arguments)
        }.count == 1)

        var exitRequest: RemoteProcessRequest?
        while let request = await requests.next() {
            if Self.isControlCommand("exit", in: request.arguments) {
                exitRequest = request
                break
            }
        }
        let reapingRequest = try #require(exitRequest)
        #expect(
            reapingRequest.arguments.contains(
                "ControlPath=\(ResolvedControlPathFixture.path)"
            )
        )
        #expect(!reapingRequest.arguments.contains("-R"))
        #expect(launcher.launchCount == 0)
        #expect(await clock.nextRequestedDelay() == 2_000)
        #expect(runner.requests.filter {
            Self.isControlCommand("forward", in: $0.arguments)
        }.count == 1)

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @MainActor
    @Test("A successful reap invalidates every sibling transport")
    func successfulReapInvalidatesSiblingTransport() async throws {
        let runner = InheritedMasterReapProcessRunner()
        let broker = NativeSSHConnectionBroker(
            sharingOptions: SSHConnectionSharingOptions(),
            clock: RecordingImmediateClock(),
            jitterMilliseconds: { 200 },
            cleanupLauncher: { _ in },
            inheritedMasterReapRunner: runner,
            controlMasterOwnershipRegistry:
                PermissiveNativeSSHControlMasterOwnershipRegistry()
        )
        let firstClock = ManualBrokerClock()
        let siblingClock = ManualBrokerClock()
        let firstFixture = try Self.makeCoordinator(
            broker: broker,
            runner: runner,
            clock: firstClock,
            ownerWorkspaceID: UUID()
        )
        let siblingFixture = try Self.makeCoordinator(
            broker: broker,
            runner: runner,
            clock: siblingClock,
            ownerWorkspaceID: UUID()
        )
        let first = firstFixture.coordinator
        let sibling = siblingFixture.coordinator
        defer {
            try? FileManager.default.removeItem(
                at: firstFixture.scratchDirectory
            )
            try? FileManager.default.removeItem(
                at: siblingFixture.scratchDirectory
            )
        }

        let events = try #require(
            await broker.controlMasterReapEvents(
                controlPath: ResolvedControlPathFixture.path
            )
        )
        let siblingObserver = Task {
            var iterator = events.makeAsyncIterator()
            guard let eventID = await iterator.next() else { return }
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                sibling.queue.async {
                    sibling.handleSharedControlMasterReapLocked(
                        eventID: eventID
                    )
                    continuation.resume()
                }
            }
        }
        sibling.queue.sync {
            sibling.daemonReady = true
            sibling.daemonRemotePath = "/tmp/cmuxd-remote"
            sibling.reverseRelayControlMasterForwardSpec =
                "127.0.0.1:64045:127.0.0.1:55002"
        }
        first.queue.sync {
            first.daemonReady = true
            first.daemonRemotePath = "/tmp/cmuxd-remote"
            first.startReverseRelayLocked(
                remotePath: "/tmp/cmuxd-remote"
            )
        }

        #expect(await firstClock.nextRequestedDelay() == 2_000)
        #expect(await siblingClock.nextRequestedDelay() == 2_000)
        await siblingObserver.value
        #expect(first.queue.sync {
            !first.daemonReady &&
                first.reverseRelayControlMasterForwardSpec == nil
        })
        #expect(sibling.queue.sync {
            !sibling.daemonReady &&
                sibling.reverseRelayControlMasterForwardSpec == nil
        })
        #expect(runner.requests.filter {
            Self.isControlCommand("exit", in: $0.arguments)
        }.count == 1)

        _ = await first.stopAndWait(cleanupScope: .transport)
        _ = await sibling.stopAndWait(cleanupScope: .transport)
    }

    @Test("Stopping detaches from an in-flight inherited-master reap")
    func stopDetachesFromInheritedMasterReap() async throws {
        let runner = BlockingInheritedMasterReapRunner()
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(
                runner: runner,
                persistentDaemonSlot: "ssh-persistent-slot"
            )
        let coordinator = fixture.coordinator
        defer {
            try? FileManager.default.removeItem(
                at: fixture.scratchDirectory
            )
        }
        var exitStarts = runner.exitStarts.makeAsyncIterator()
        var exitFinishes = runner.exitFinishes.makeAsyncIterator()

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(
                remotePath: "/tmp/cmuxd-remote"
            )
        }
        #expect(await exitStarts.next() != nil)

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
        #expect(coordinator.queue.sync {
            coordinator.controlMasterReapState.startupPhase
                .allowsRelayLaunch
        })

        runner.finishExit()
        #expect(await exitFinishes.next() != nil)
    }

    @MainActor
    private static func makeCoordinator(
        broker: NativeSSHConnectionBroker,
        runner: any RemoteSessionProcessRunning,
        clock: any RemoteProxyRetryClock,
        ownerWorkspaceID: UUID
    ) throws -> (
        coordinator: RemoteSessionCoordinator,
        scratchDirectory: URL
    ) {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-inherited-master-reap-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true
        )
        let configuration = broker.retainWorkspace(
            WorkspaceRemoteConfiguration(
                destination: "user@example.test",
                port: nil,
                identityFile: nil,
                sshOptions: [
                    "ControlMaster=auto",
                    "ControlPersist=600",
                    "ControlPath=\(ResolvedControlPathFixture.path)",
                ],
                localProxyPort: nil,
                relayPort: 64_044,
                relayID: "relay-startup-cancellation",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: scratchDirectory
                    .appendingPathComponent("relay.sock").path,
                ownerWorkspaceID: ownerWorkspaceID,
                terminalStartupCommand: nil,
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "ssh-persistent-slot"
            )
        )
        return (
            RemoteSessionCoordinator(
                host: NoopRemoteSessionHost(),
                configuration: configuration,
                proxyBroker: SSHOverrideUnusedRemoteProxyBroker(),
                connectionBroker: broker,
                manifestRepository: RemoteDaemonManifestRepository(
                    homeDirectory: scratchDirectory
                ),
                processRunner: runner,
                reverseRelayLauncher: RecordingReverseRelayLauncher(),
                reachabilityProbe: SSHOverrideNoopReachabilityProbe(),
                relayCommandRewriter:
                    SSHOverridePassthroughRelayCommandRewriter(),
                buildInfo: SSHOverrideStubBuildInfo(),
                daemonStrings: RemoteDaemonStrings(
                    missingPersistentPTYCapability: "",
                    missingRequiredFunctionality: ""
                ),
                strings: RemoteSessionStrings(
                    connectedVMNoProxyFormat: "%@",
                    suspendedDetailFormat: "%@",
                    reverseRelayUnavailableRetrying:
                        "test relay unavailable",
                    reverseRelayPortUnavailableRetrying:
                        "test relay port unavailable",
                    controlMasterOwnershipUnavailable:
                        "test control master unavailable"
                ),
                clock: clock
            ),
            scratchDirectory
        )
    }

    private static func isControlCommand(
        _ command: String,
        in arguments: [String]
    ) -> Bool {
        arguments.indices.dropLast().contains(where: {
            arguments[$0] == "-O" && arguments[$0 + 1] == command
        })
    }
}
