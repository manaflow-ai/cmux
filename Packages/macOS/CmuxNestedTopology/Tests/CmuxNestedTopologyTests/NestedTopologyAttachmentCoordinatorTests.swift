#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedTopologyAttachmentCoordinatorTests {
    @Test func proposalAloneDoesNotAuthorizeAttachment() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake() },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA
                )
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        await coordinator.recordProposal(
            NestedAttachmentProposal(
                hostWorkspaceID: AttachmentTestFixtures.workspaceA,
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                providerKind: .herdr,
                suggestedSocketPath: AttachmentTestFixtures.endpoint.canonicalPath,
                source: .environment
            )
        )
        #expect(await coordinator.pendingProposal(for: AttachmentTestFixtures.surfaceA) != nil)
        #expect(await coordinator.attachment(for: AttachmentTestFixtures.surfaceA) == nil)

        do {
            _ = try await coordinator.attach(
                hostWorkspaceID: AttachmentTestFixtures.workspaceA,
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                providerKind: .herdr,
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
                authorization: nil
            )
            Issue.record("expected opt-in required")
        } catch let error as NestedAttachmentError {
            #expect(error == .optInRequired)
        }

        #expect(await coordinator.attachment(for: AttachmentTestFixtures.surfaceA) == nil)
        #expect(await client.handshakeCount == 0)
    }

    @Test func userConfirmedAttachBecomesLiveAndAcquiresPluginHandoff() async throws {
        let telemetry = TelemetryCapture()
        let envMirror = EnvironmentMirrorCapture()
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let attachmentIDBox = MutexBox<UUID?>(nil)
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "live-1") },
            snapshot: {
                let id = attachmentIDBox.get() ?? UUID()
                return AttachmentTestFixtures.snapshot(
                    attachmentID: id,
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "live-1"
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    // Keep stream open until cancelled so attachment stays live.
                    continuation.onTermination = { _ in }
                }
            }
        )

        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir),
            telemetrySink: { event in
                telemetry.append(event)
            },
            environmentMirrorSink: { value in
                envMirror.set(value)
            }
        )

        let record = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        attachmentIDBox.set(record.attachmentID)

        #expect(record.state == .live)
        #expect(record.pluginWriterHandoffActive)
        #expect(record.providerInstanceID?.rawValue == "live-1")
        #expect(record.capabilities.contains(.topologySnapshotV1))
        #expect(await coordinator.shouldSuppressPluginWriters(for: AttachmentTestFixtures.surfaceA))

        let handoff = NestedPluginWriterHandoff(directoryURL: handoffDir)
        #expect(handoff.isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceA))
        #expect(
            handoff.shouldSuppressPluginWriters(
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                environment: [:]
            )
        )
        #expect(envMirror.get().contains(AttachmentTestFixtures.surfaceA.uuidString.lowercased()))
        let events = telemetry.snapshot()
        #expect(events.contains(where: { $0.name == "attach_live" && $0.state == .live }))
        #expect(events.allSatisfy { event in
            // Default telemetry must never carry a socket path field/value.
            String(describing: event).contains("/tmp/") == false
        })
    }

    @Test func endpointSecurityFailuresRejectWithoutConnecting() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake() },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA
                )
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(
                preConnectResult: .failure(.wrongOwner(expected: 1, actual: 2))
            ),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        do {
            _ = try await coordinator.attach(
                hostWorkspaceID: AttachmentTestFixtures.workspaceA,
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                providerKind: .herdr,
                socketPath: "/tmp/unused.sock",
                authorization: .userConfirmed
            )
            Issue.record("expected rejection")
        } catch let error as NestedAttachmentError {
            guard case .endpointRejected(.wrongOwner) = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }

        let record = await coordinator.attachment(for: AttachmentTestFixtures.surfaceA)
        #expect(record?.state == .rejected)
        #expect(await client.handshakeCount == 0)
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceA) == false
        )
    }

    @Test func pathIdentityMismatchAroundConnectRejects() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake() },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA
                )
            }
        )
        let swapped = NestedUnixSocketFileIdentity(deviceID: 9, inode: 99)
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(
                preConnectResult: .success(AttachmentTestFixtures.endpoint),
                revalidateError: .identityMismatch(
                    expected: AttachmentTestFixtures.endpoint.fileIdentity,
                    actual: swapped
                )
            ),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        do {
            _ = try await coordinator.attach(
                hostWorkspaceID: AttachmentTestFixtures.workspaceA,
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                providerKind: .herdr,
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
                authorization: .userConfirmed
            )
            Issue.record("expected identity mismatch rejection")
        } catch let error as NestedAttachmentError {
            guard case .endpointRejected(.identityMismatch) = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }

        #expect(await coordinator.attachment(for: AttachmentTestFixtures.surfaceA)?.state == .rejected)
    }

    @Test func duplicateAttachmentRejected() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake() },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in }
                }
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        _ = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )

        do {
            _ = try await coordinator.attach(
                hostWorkspaceID: AttachmentTestFixtures.workspaceA,
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                providerKind: .herdr,
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
                authorization: .userConfirmed
            )
            Issue.record("expected duplicate rejection")
        } catch let error as NestedAttachmentError {
            guard case .duplicateAttachment(let surface) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(surface == AttachmentTestFixtures.surfaceA)
        }
    }

    @Test func hostMovePreservesAttachmentHostCloseDetachesWithoutProviderStop() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }
        // Detach must never invoke a provider stop RPC; this stub has no stop method.
        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake(instance: "move-1") },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    instance: "move-1"
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in }
                }
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        let attached = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .authenticatedControlSocket(requestID: "req-1")
        )
        let attachmentID = attached.attachmentID

        await coordinator.noteHostSurfaceMoved(
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            toWorkspaceID: AttachmentTestFixtures.workspaceB
        )
        let moved = await coordinator.attachment(for: AttachmentTestFixtures.surfaceA)
        #expect(moved?.attachmentID == attachmentID)
        #expect(moved?.hostWorkspaceID == AttachmentTestFixtures.workspaceB)
        #expect(moved?.state == .live)
        #expect(moved?.providerInstanceID?.rawValue == "move-1")

        await coordinator.noteHostSurfaceClosed(
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA
        )
        #expect(await coordinator.attachment(for: AttachmentTestFixtures.surfaceA) == nil)
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceA) == false
        )
    }

    @Test func teardownCancelsAllAttachmentsAndReleasesHandoffs() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        @Sendable func makeClient(surface: UUID, instance: String) -> StubNestedTopologyProviderClient {
            StubNestedTopologyProviderClient(
                handshake: { AttachmentTestFixtures.handshake(instance: instance) },
                snapshot: {
                    AttachmentTestFixtures.snapshot(
                        attachmentID: UUID(),
                        hostStableSurfaceID: surface,
                        instance: instance
                    )
                },
                events: {
                    AsyncThrowingStream { continuation in
                        continuation.onTermination = { _ in }
                    }
                }
            )
        }

        // Attach two surfaces through a sequencing factory, then prove teardown
        // clears every attachment and releases both handoffs.
        let factory = SequencingClientFactory { configuration in
            makeClient(
                surface: configuration.hostStableSurfaceID,
                instance: configuration.hostStableSurfaceID == AttachmentTestFixtures.surfaceA ? "t1" : "t2"
            )
        }
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: factory,
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )
        _ = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        _ = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceB,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        await coordinator.teardown()
        #expect(await coordinator.allAttachments().isEmpty)
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceA) == false
        )
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceB) == false
        )
    }

    @Test func reconnectCancellationDuringConnecting() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let gate = AsyncGate()
        let client = StubNestedTopologyProviderClient(
            handshake: {
                await gate.wait()
                try Task.checkCancellation()
                return AttachmentTestFixtures.handshake()
            },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA
                )
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        let attachTask = Task {
            try await coordinator.attach(
                hostWorkspaceID: AttachmentTestFixtures.workspaceA,
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                providerKind: .herdr,
                socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
                authorization: .userConfirmed
            )
        }

        // Wait until connecting is visible, then cancel via detach.
        var sawConnecting = false
        for _ in 0..<100 {
            if await coordinator.attachment(for: AttachmentTestFixtures.surfaceA)?.state == .connecting {
                sawConnecting = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sawConnecting)

        await coordinator.detach(
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            reason: .cancelled
        )
        await gate.open()

        do {
            _ = try await attachTask.value
            Issue.record("expected cancellation")
        } catch let error as NestedAttachmentError {
            #expect(error == .cancelled)
        } catch is CancellationError {
            // Acceptable if Task cancellation surfaces directly.
        }

        #expect(await coordinator.attachment(for: AttachmentTestFixtures.surfaceA) == nil)
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceA) == false
        )
    }

    @Test func twoSessionsWithIdenticalRawIDsRemainIsolated() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let factory = SequencingClientFactory { configuration in
            let surface = configuration.hostStableSurfaceID
            let instance = surface == AttachmentTestFixtures.surfaceA ? "gen-a" : "gen-b"
            return StubNestedTopologyProviderClient(
                handshake: { AttachmentTestFixtures.handshake(instance: instance) },
                snapshot: {
                    AttachmentTestFixtures.snapshot(
                        attachmentID: configuration.attachmentID,
                        hostStableSurfaceID: surface,
                        instance: instance,
                        paneRawID: "w1:p1" // identical raw ID across providers
                    )
                },
                events: {
                    AsyncThrowingStream { continuation in
                        continuation.onTermination = { _ in }
                    }
                }
            )
        }

        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: factory,
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        let a = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )
        let b = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceB,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceB,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )

        #expect(a.attachmentID != b.attachmentID)
        #expect(a.providerInstanceID != b.providerInstanceID)
        let paneA = a.latestSnapshot?.panes.first?.id
        let paneB = b.latestSnapshot?.panes.first?.id
        #expect(paneA?.rawID == "w1:p1")
        #expect(paneB?.rawID == "w1:p1")
        #expect(paneA != paneB)
        #expect(paneA?.providerInstanceID != paneB?.providerInstanceID)

        let resolvedA = try await coordinator.resolveLiveAttachment(
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            expectedAttachmentID: a.attachmentID,
            expectedProviderInstanceID: a.providerInstanceID
        )
        #expect(resolvedA.attachmentID == a.attachmentID)

        do {
            _ = try await coordinator.resolveLiveAttachment(
                hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                expectedAttachmentID: b.attachmentID,
                expectedProviderInstanceID: b.providerInstanceID
            )
            Issue.record("expected cross-attachment resolve failure")
        } catch let error as NestedAttachmentError {
            guard case .providerInstanceMismatch = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
    }

    @Test func pluginHandoffReleasedWhenLeavingLive() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let client = StubNestedTopologyProviderClient(
            handshake: { AttachmentTestFixtures.handshake() },
            snapshot: {
                AttachmentTestFixtures.snapshot(
                    attachmentID: UUID(),
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA
                )
            },
            events: {
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: NestedTopologyProviderError.unexpectedEOF)
                }
            }
        )
        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: StubEndpointValidator(preConnectResult: .success(AttachmentTestFixtures.endpoint)),
            clientFactory: StubNestedTopologyProviderClientFactory(client: client),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir)
        )

        _ = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: AttachmentTestFixtures.endpoint.canonicalPath,
            authorization: .userConfirmed
        )

        var becameStale = false
        for _ in 0..<100 {
            if await coordinator.attachment(for: AttachmentTestFixtures.surfaceA)?.state == .stale {
                becameStale = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(becameStale)

        let record = await coordinator.attachment(for: AttachmentTestFixtures.surfaceA)
        #expect(record?.pluginWriterHandoffActive == false)
        #expect(await coordinator.shouldSuppressPluginWriters(for: AttachmentTestFixtures.surfaceA) == false)
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .isHeld(hostStableSurfaceID: AttachmentTestFixtures.surfaceA) == false
        )
        #expect(
            NestedPluginWriterHandoff(directoryURL: handoffDir)
                .shouldSuppressPluginWriters(
                    hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
                    environment: [
                        NestedPluginWriterHandoff.forcePluginWritersEnvironmentKey: "1",
                    ]
                ) == false
        )
    }

    @Test func realSocketAttachEndToEndWithSecurityChecks() async throws {
        let handoffDir = try AttachmentTestFixtures.makeHandoffDirectory()
        defer { try? FileManager.default.removeItem(at: handoffDir) }

        let server = try FakeHerdrUnixSocketServer { _, id, method in
            switch method {
            case "ping":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
            case "session.snapshot":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.snapshotJSON(id: id))]
            case "events.subscribe":
                return [
                    HerdrFakeFixtures.line(HerdrFakeFixtures.subscriptionStartedJSON(id: id)),
                    HerdrFakeFixtures.line(HerdrFakeFixtures.workspaceCreatedEventJSON()),
                ]
            default:
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.errorJSON(id: id))]
            }
        }
        defer { server.shutdown() }
        #if canImport(Darwin)
        _ = chmod(server.path, 0o600)
        #else
        _ = chmod(server.path, 0o600)
        #endif

        let coordinator = NestedTopologyAttachmentCoordinator(
            validator: NestedUnixSocketEndpointValidator(expectedOwnerUID: geteuid()),
            clientFactory: HerdrNestedTopologyClientFactory(),
            handoff: NestedPluginWriterHandoff(directoryURL: handoffDir),
            clientConfigurationDefaults: .init(
                connectTimeout: .seconds(2),
                requestTimeout: .seconds(2)
            )
        )

        let record = try await coordinator.attach(
            hostWorkspaceID: AttachmentTestFixtures.workspaceA,
            hostStableSurfaceID: AttachmentTestFixtures.surfaceA,
            providerKind: .herdr,
            socketPath: server.path,
            authorization: .userConfirmed
        )
        #expect(record.state == .live)
        #expect(record.latestSnapshot?.workspaces.isEmpty == false)
        let endpoint = try #require(record.endpoint)
        let expectedCanonical = try NestedUnixSocketEndpointValidator(expectedOwnerUID: geteuid())
            .canonicalize(server.path)
        #expect(endpoint.canonicalPath == expectedCanonical)

        await coordinator.teardown()
    }
}

// MARK: - Test helpers

final class MutexBox<Value>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmux.nested.mutexbox")
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    func get() -> Value {
        queue.sync { storage }
    }

    func set(_ value: Value) {
        queue.sync { storage = value }
    }

    @discardableResult
    func mutate<R>(_ body: (inout Value) -> R) -> R {
        queue.sync { body(&storage) }
    }
}

private final class TelemetryCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmux.nested.telemetry")
    private var events: [NestedAttachmentTelemetryEvent] = []

    func append(_ event: NestedAttachmentTelemetryEvent) {
        queue.sync { events.append(event) }
    }

    func snapshot() -> [NestedAttachmentTelemetryEvent] {
        queue.sync { events }
    }
}

private final class EnvironmentMirrorCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmux.nested.envmirror")
    private var value = ""

    func set(_ value: String) {
        queue.sync { self.value = value }
    }

    func get() -> String {
        queue.sync { value }
    }
}

actor AsyncGate {
    private var openFlag = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if openFlag { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        openFlag = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

struct SequencingClientFactory: NestedTopologyProviderClientFactory, Sendable {
    let make: @Sendable (HerdrNestedTopologyClientConfiguration) -> any NestedTopologyProviderClient

    func makeHerdrClient(
        configuration: HerdrNestedTopologyClientConfiguration
    ) -> any NestedTopologyProviderClient {
        make(configuration)
    }
}
