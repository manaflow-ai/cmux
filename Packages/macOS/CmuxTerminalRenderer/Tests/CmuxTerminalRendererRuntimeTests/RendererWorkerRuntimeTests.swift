import CoreFoundation
import CmuxTerminalRendererControl
import CmuxTerminalRendererRuntime
import CmuxTerminalRenderProtocol
import CmuxTerminalRenderTransport
import Darwin
import Foundation
import IOSurface
import Testing

private let daemonID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let workspaceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let terminalID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private let presentationID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

@Suite("Renderer worker runtime")
struct RendererWorkerRuntimeTests {
    @Test("launch configuration requires exact nonzero identities")
    func launchConfiguration() throws {
        let configuration = try RendererWorkerLaunchConfiguration(
            arguments: [
                "--workspace", workspaceID.uuidString,
                "--renderer-epoch", "9",
            ],
            environment: [
                "CMUX_RENDERER_CONTROL_FD": "198",
                "CMUX_DAEMON_INSTANCE_ID": daemonID.uuidString,
            ]
        )
        #expect(configuration.controlDescriptor == 198)
        #expect(configuration.expectation == RendererWorkerExpectation(
            daemonInstanceID: daemonID,
            workspaceID: workspaceID,
            rendererEpoch: 9
        ))
        #expect(throws: RendererWorkerLaunchConfigurationError.invalidRendererEpoch) {
            _ = try RendererWorkerLaunchConfiguration(
                arguments: [
                    "--workspace", workspaceID.uuidString,
                    "--renderer-epoch", "0",
                ],
                environment: [
                    "CMUX_RENDERER_CONTROL_FD": "198",
                    "CMUX_DAEMON_INSTANCE_ID": daemonID.uuidString,
                ]
            )
        }
    }

    @Test("bootstrap sends ready only after launch identity matches")
    func bootstrapIdentity() async throws {
        let (runtime, _) = try makeRuntime()
        let result = await runtime.handle(.bootstrap(try RendererBootstrap(
            daemonInstanceID: daemonID,
            workspaceID: workspaceID,
            rendererEpoch: 9
        )))
        #expect(result.shouldExit == false)
        guard case let .ready(ready) = try #require(result.replies.first) else {
            Issue.record("expected ready")
            return
        }
        #expect(ready.processID == 7_777)
        #expect(ready.effectiveUserID == 501)

        let (mismatchedRuntime, _) = try makeRuntime()
        let mismatch = await mismatchedRuntime.handle(.bootstrap(try RendererBootstrap(
            daemonInstanceID: daemonID,
            workspaceID: workspaceID,
            rendererEpoch: 10
        )))
        #expect(mismatch.shouldExit)
        guard case let .fatal(fatal) = try #require(mismatch.replies.first) else {
            Issue.record("expected fatal")
            return
        }
        #expect(fatal.code == .protocolViolation)
    }

    @Test("sent IOSurface lease remains owned until exact host release")
    func exactLeaseRelease() async throws {
        let (runtime, factory) = try makeRuntime()
        try await activate(runtime)
        let attachment = try makeAttachment(generation: 1)
        #expect((await runtime.handle(.upsertPresentation(attachment))).replies.isEmpty)
        let scene = try makeScene(generation: 1, canonical: 41, presentation: 3)
        let sceneResult = await runtime.handle(.semanticScene(scene))
        guard case let .presentationReady(metrics) = try #require(sceneResult.replies.first) else {
            Issue.record("expected presentation-ready metrics")
            return
        }
        #expect(metrics.canonicalSequence == 41)
        #expect(metrics.presentationSequence == 3)
        #expect(metrics.columns == 80)
        #expect(metrics.rows == 24)
        #expect(metrics.cellWidth == 10)
        #expect(metrics.cellHeight == 20)
        #expect(metrics.paddingTop == 4)
        #expect(metrics.paddingRight == 5)
        #expect(metrics.paddingBottom == 6)
        #expect(metrics.paddingLeft == 7)

        let engine = try #require(factory.engines[presentationID])
        #expect(engine.appliedScenes == [Data([0x01, 0x02, 0x03])])
        #expect(engine.publishedMetadata.count == 1)
        #expect(engine.releasedLeases.isEmpty)
        let metadata = try #require(engine.publishedMetadata.first)
        #expect(metadata.daemonInstanceID == daemonID)
        #expect(metadata.terminalSequence == 41)
        #expect(metadata.completionFence == .producerCompleted)

        let result = await runtime.handle(.frameRelease(try release(
            metadata: metadata,
            surfaceID: 901
        )))
        #expect(result.shouldExit == false)
        #expect(engine.releasedLeases.map(\.frameSequence) == [1])
    }

    @Test("retired generation keeps only its outstanding lease")
    func retiredGenerationTombstone() async throws {
        let (runtime, factory) = try makeRuntime()
        try await activate(runtime)
        let attachment = try makeAttachment(generation: 1)
        _ = await runtime.handle(.upsertPresentation(attachment))
        _ = await runtime.handle(.semanticScene(try makeScene(
            generation: 1,
            canonical: 5,
            presentation: 1
        )))
        let engine = try #require(factory.engines[presentationID])
        let metadata = try #require(engine.publishedMetadata.first)

        let removal = try RendererPresentationRemoval(
            terminalID: terminalID,
            terminalEpoch: 4,
            presentationID: presentationID,
            presentationGeneration: 1
        )
        let removalResult = await runtime.handle(.removePresentation(removal))
        #expect(removalResult.shouldExit == false)
        #expect(removalResult.replies == [
            .presentationRemoved(try RendererPresentationRemoved(
                terminalID: terminalID,
                terminalEpoch: 4,
                presentationID: presentationID,
                presentationGeneration: 1
            )),
        ])
        #expect(engine.closed == false)

        #expect((await runtime.handle(.frameRelease(try release(
            metadata: metadata,
            surfaceID: 901
        )))).shouldExit == false)
        #expect(engine.closed)
        #expect(engine.releasedLeases.count == 1)
    }

    @Test("quiescence acknowledgement lets host drain a full Mach queue and reap leases")
    func quiescedFullQueueDrain() async throws {
        let fence = try TerminalRenderPresentationFence(
            daemonInstanceID: daemonID,
            rendererEpoch: 9,
            terminalID: terminalID,
            terminalEpoch: 4,
            minimumTerminalSequence: 0,
            presentationID: presentationID,
            presentationGeneration: 1,
            width: 32,
            height: 24,
            pixelFormat: .bgra8Unorm,
            colorSpace: .sRGB,
            completionRequirement: .producerCompleted
        )
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: TerminalRenderWorkerIdentity(
                processID: getpid(),
                effectiveUserID: geteuid(),
                processInstanceToken: TerminalRenderProcessInstanceToken(
                    startTimeSeconds: 1,
                    startTimeMicroseconds: 2
                )
            ),
            initialFence: fence,
            queueLimit: 3
        )
        let factory = TransportEngineFactory()
        let runtime = RendererWorkerRuntime(
            expectation: RendererWorkerExpectation(
                daemonInstanceID: daemonID,
                workspaceID: workspaceID,
                rendererEpoch: 9
            ),
            ready: try RendererWorkerReady(
                processID: UInt32(getpid()),
                effectiveUserID: geteuid(),
                sceneCapabilities: .allKnown
            ),
            engineFactory: factory
        )
        try await activate(runtime)
        let attachment = try RendererPresentationAttachment(
            terminalID: terminalID,
            terminalEpoch: 4,
            presentationID: presentationID,
            presentationGeneration: 1,
            width: 32,
            height: 24,
            backingScaleFactor: 1,
            pixelFormat: .bgra8Unorm,
            colorSpace: .sRGB,
            frameEndpoint: receiver.endpoint,
            resolvedConfigRevision: 1,
            resolvedConfig: Data("font-family = Menlo".utf8)
        )
        _ = await runtime.handle(.upsertPresentation(attachment))
        for sequence in UInt64(1)...3 {
            let result = await runtime.handle(.semanticScene(try makeScene(
                generation: 1,
                canonical: sequence,
                presentation: sequence
            )))
            #expect(!result.shouldExit)
        }
        let engine = try #require(factory.engine)
        #expect(engine.releasedLeases.isEmpty)

        let removal = try RendererPresentationRemoval(
            terminalID: terminalID,
            terminalEpoch: 4,
            presentationID: presentationID,
            presentationGeneration: 1
        )
        let removalResult = await runtime.handle(.removePresentation(removal))
        #expect(removalResult.replies == [
            .presentationRemoved(try RendererPresentationRemoved(
                terminalID: terminalID,
                terminalEpoch: 4,
                presentationID: presentationID,
                presentationGeneration: 1
            )),
        ])
        #expect(!engine.closed)

        let retryBeforeDrain = await runtime.handle(.removePresentation(removal))
        #expect(retryBeforeDrain.replies == removalResult.replies)
        #expect(!retryBeforeDrain.shouldExit)

        let releases = try await receiver.drainQuiescedFrames()
        #expect(releases.count == 3)
        for receipt in releases {
            _ = await runtime.handle(.frameRelease(try release(
                metadata: receipt.metadata,
                surfaceID: receipt.surfaceID
            )))
        }
        #expect(engine.releasedLeases.map(\.frameSequence).sorted() == [1, 2, 3])
        #expect(engine.closed)
        let retryAfterReap = await runtime.handle(.removePresentation(removal))
        #expect(retryAfterReap.replies == removalResult.replies)
        #expect(!retryAfterReap.shouldExit)
        await receiver.stop()
    }

    @Test("queue-full frame is released locally and latest scene remains pending")
    func queueFullDropsLease() async throws {
        let (runtime, factory) = try makeRuntime()
        try await activate(runtime)
        _ = await runtime.handle(.upsertPresentation(try makeAttachment(generation: 1)))
        let engine = try #require(factory.engines[presentationID])
        engine.publishDisposition = .droppedQueueFull

        let result = await runtime.handle(.semanticScene(try makeScene(
            generation: 1,
            canonical: 7,
            presentation: 2
        )))
        #expect(result.shouldExit == false)
        #expect(engine.releasedLeases.map(\.frameSequence) == [1])
    }

    @Test("scene decode failure requests a full scene without killing worker")
    func decodeFailureRequestsFullScene() async throws {
        let (runtime, factory) = try makeRuntime()
        try await activate(runtime)
        _ = await runtime.handle(.upsertPresentation(try makeAttachment(generation: 1)))
        let engine = try #require(factory.engines[presentationID])
        engine.applyError = .invalidScene

        let result = await runtime.handle(.semanticScene(try makeScene(
            generation: 1,
            canonical: 9,
            presentation: 2
        )))
        #expect(result.shouldExit == false)
        guard case let .needsFullScene(request) = try #require(result.replies.first) else {
            Issue.record("expected needs-full-scene")
            return
        }
        #expect(request.reason == .decodeFailure)
        #expect(request.lastCanonicalSequence == 0)
    }

    @Test("animation clock stops at three leases and resumes after exact release")
    func animationLeaseBackpressure() async throws {
        let scheduler = ManualAnimationScheduler()
        let (runtime, factory) = try makeRuntime(animationScheduler: scheduler)
        try await activate(runtime)
        _ = await runtime.handle(.upsertPresentation(try makeAttachment(generation: 1)))
        let engine = try #require(factory.engines[presentationID])
        engine.animationEnabled = true

        _ = await runtime.handle(.semanticScene(try makeScene(
            generation: 1,
            canonical: 11,
            presentation: 2
        )))
        #expect(engine.publishedMetadata.count == 1)
        #expect(scheduler.activeCount == 1)

        await scheduler.fireNext()
        #expect(engine.publishedMetadata.count == 2)
        #expect(scheduler.activeCount == 1)
        await scheduler.fireNext()
        #expect(engine.publishedMetadata.count == 3)
        #expect(scheduler.activeCount == 0)

        let first = try #require(engine.publishedMetadata.first)
        _ = await runtime.handle(.frameRelease(try release(
            metadata: first,
            surfaceID: 901
        )))
        #expect(scheduler.activeCount == 1)
        await scheduler.fireNext()
        #expect(engine.publishedMetadata.count == 4)
        #expect(engine.releasedLeases.map(\.frameSequence) == [1])
        #expect(scheduler.activeCount == 0)
    }

    @Test("inactive and visibility-detached presentations schedule zero animation work")
    func dormantAnimationClock() async throws {
        let inactiveScheduler = ManualAnimationScheduler()
        let (inactiveRuntime, inactiveFactory) = try makeRuntime(
            animationScheduler: inactiveScheduler
        )
        try await activate(inactiveRuntime)
        _ = await inactiveRuntime.handle(.upsertPresentation(
            try makeAttachment(generation: 1)
        ))
        let inactiveEngine = try #require(inactiveFactory.engines[presentationID])
        inactiveEngine.animationEnabled = false
        _ = await inactiveRuntime.handle(.semanticScene(try makeScene(
            generation: 1,
            canonical: 21,
            presentation: 1
        )))
        #expect(inactiveScheduler.activeCount == 0)

        let detachedScheduler = ManualAnimationScheduler()
        let (detachedRuntime, detachedFactory) = try makeRuntime(
            animationScheduler: detachedScheduler
        )
        try await activate(detachedRuntime)
        _ = await detachedRuntime.handle(.upsertPresentation(
            try makeAttachment(generation: 1)
        ))
        let detachedEngine = try #require(detachedFactory.engines[presentationID])
        detachedEngine.animationEnabled = true
        _ = await detachedRuntime.handle(.semanticScene(try makeScene(
            generation: 1,
            canonical: 22,
            presentation: 1
        )))
        #expect(detachedScheduler.activeCount == 1)
        _ = await detachedRuntime.handle(.removePresentation(
            try RendererPresentationRemoval(
                terminalID: terminalID,
                terminalEpoch: 4,
                presentationID: presentationID,
                presentationGeneration: 1
            )
        ))
        #expect(detachedScheduler.activeCount == 0)
        await detachedScheduler.fireNext()
        #expect(detachedEngine.publishedMetadata.count == 1)
    }

    private func makeRuntime(
        animationScheduler: any RendererAnimationScheduling =
            RendererDisplayAnimationScheduler()
    ) throws -> (RendererWorkerRuntime, FakeEngineFactory) {
        let factory = FakeEngineFactory()
        let ready = try RendererWorkerReady(
            processID: 7_777,
            effectiveUserID: 501,
            sceneCapabilities: .allKnown
        )
        return (
            RendererWorkerRuntime(
                expectation: RendererWorkerExpectation(
                    daemonInstanceID: daemonID,
                    workspaceID: workspaceID,
                    rendererEpoch: 9
                ),
                ready: ready,
                engineFactory: factory,
                animationScheduler: animationScheduler
            ),
            factory
        )
    }

    private func activate(_ runtime: RendererWorkerRuntime) async throws {
        let result = await runtime.handle(.bootstrap(try RendererBootstrap(
            daemonInstanceID: daemonID,
            workspaceID: workspaceID,
            rendererEpoch: 9
        )))
        #expect(result.shouldExit == false)
    }

    private func makeAttachment(
        generation: UInt64
    ) throws -> RendererPresentationAttachment {
        try RendererPresentationAttachment(
            terminalID: terminalID,
            terminalEpoch: 4,
            presentationID: presentationID,
            presentationGeneration: generation,
            width: 800,
            height: 600,
            backingScaleFactor: 2,
            pixelFormat: .bgra8Unorm,
            colorSpace: .sRGB,
            frameEndpoint: TerminalRenderFrameEndpoint(
                serviceName: "com.cmux.test.renderer",
                capability: Data(repeating: 0x5a, count: 32)
            ),
            resolvedConfigRevision: 1,
            resolvedConfig: Data("font-family = Menlo".utf8)
        )
    }

    private func makeScene(
        generation: UInt64,
        canonical: UInt64,
        presentation: UInt64
    ) throws -> RendererSemanticScene {
        try RendererSemanticScene(
            terminalID: terminalID,
            terminalEpoch: 4,
            presentationID: presentationID,
            presentationGeneration: generation,
            canonicalSequence: canonical,
            presentationSequence: presentation,
            bytes: Data([0x01, 0x02, 0x03])
        )
    }

    private func release(
        metadata: TerminalRenderFrameMetadata,
        surfaceID: UInt32
    ) throws -> RendererControlFrameRelease {
        try RendererControlFrameRelease(
            daemonInstanceID: metadata.daemonInstanceID,
            rendererEpoch: metadata.rendererEpoch,
            terminalID: metadata.terminalID,
            terminalEpoch: metadata.terminalEpoch,
            terminalSequence: metadata.terminalSequence,
            presentationID: metadata.presentationID,
            presentationGeneration: metadata.presentationGeneration,
            frameSequence: metadata.frameSequence,
            surfaceID: surfaceID
        )
    }
}

private final class FakeEngineFactory: RendererPresentationEngineFactory, @unchecked Sendable {
    var engines: [UUID: FakeEngine] = [:]

    func makeEngine(
        context: RendererPresentationEngineContext
    ) throws -> any RendererPresentationEngine {
        let engine = FakeEngine(context: context)
        engines[context.attachment.presentationID] = engine
        return engine
    }
}

private final class FakeEngine: RendererPresentationEngine, @unchecked Sendable {
    let context: RendererPresentationEngineContext
    var appliedScenes: [Data] = []
    var publishedMetadata: [TerminalRenderFrameMetadata] = []
    var releasedLeases: [RendererFrameLease] = []
    var publishDisposition = RendererFramePublishDisposition.sent
    var applyError: RendererPresentationEngineError?
    var renderError: RendererPresentationEngineError?
    var nextFrameSequence: UInt64 = 1
    var nextTerminalSequence: UInt64 = 1
    var nextPresentationSequence: UInt64 = 1
    var closed = false
    var animationEnabled = false

    init(context: RendererPresentationEngineContext) {
        self.context = context
    }

    func apply(scene: RendererSemanticScene) throws {
        if let applyError { throw applyError }
        appliedScenes.append(scene.bytes)
        nextTerminalSequence = scene.canonicalSequence
        nextPresentationSequence = scene.presentationSequence
    }

    func metrics() throws -> RendererPresentationGeometry {
        RendererPresentationGeometry(
            columns: 80,
            rows: 24,
            cellWidth: 10,
            cellHeight: 20,
            paddingTop: 4,
            paddingRight: 5,
            paddingBottom: 6,
            paddingLeft: 7
        )
    }

    func shouldAnimate(visible: Bool) throws -> Bool {
        animationEnabled && visible
    }

    func render() throws -> RendererFrameLease {
        if let renderError { throw renderError }
        let sequence = nextFrameSequence
        nextFrameSequence += 1
        return RendererFrameLease(
            rendererEpoch: context.rendererEpoch,
            terminalID: context.attachment.terminalID,
            terminalEpoch: context.attachment.terminalEpoch,
            terminalSequence: nextTerminalSequence,
            presentationID: context.attachment.presentationID,
            presentationGeneration: context.attachment.presentationGeneration,
            presentationSequence: nextPresentationSequence,
            frameSequence: sequence,
            surfaceID: UInt32(900 + sequence),
            width: context.attachment.width,
            height: context.attachment.height
        )
    }

    func publish(
        lease _: RendererFrameLease,
        metadata: TerminalRenderFrameMetadata
    ) async throws -> RendererFramePublishDisposition {
        publishedMetadata.append(metadata)
        return publishDisposition
    }

    func release(lease: RendererFrameLease) throws {
        releasedLeases.append(lease)
    }

    func close() async throws {
        closed = true
    }
}

private final class TransportEngineFactory:
    RendererPresentationEngineFactory,
    @unchecked Sendable
{
    var engine: TransportEngine?

    func makeEngine(
        context: RendererPresentationEngineContext
    ) throws -> any RendererPresentationEngine {
        let engine = try TransportEngine(context: context)
        self.engine = engine
        return engine
    }
}

private final class TransportEngine: RendererPresentationEngine, @unchecked Sendable {
    let context: RendererPresentationEngineContext
    let sender: TerminalRenderFrameSender
    var surfaces: [UInt32: TerminalRenderSurfaceHandle] = [:]
    var releasedLeases: [RendererFrameLease] = []
    var nextFrameSequence: UInt64 = 1
    var terminalSequence: UInt64 = 1
    var presentationSequence: UInt64 = 1
    var closed = false

    init(context: RendererPresentationEngineContext) throws {
        self.context = context
        self.sender = try TerminalRenderFrameSender(
            endpoint: context.attachment.frameEndpoint
        )
    }

    func apply(scene: RendererSemanticScene) throws {
        terminalSequence = scene.canonicalSequence
        presentationSequence = scene.presentationSequence
    }

    func metrics() throws -> RendererPresentationGeometry {
        RendererPresentationGeometry(
            columns: 32,
            rows: 24,
            cellWidth: 1,
            cellHeight: 1,
            paddingTop: 0,
            paddingRight: 0,
            paddingBottom: 0,
            paddingLeft: 0
        )
    }

    func render() throws -> RendererFrameLease {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: Int(context.attachment.width),
            kIOSurfaceHeight: Int(context.attachment.height),
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: Int(context.attachment.width) * 4,
            kIOSurfaceAllocSize:
                Int(context.attachment.width) * Int(context.attachment.height) * 4,
            kIOSurfacePixelFormat: TerminalRenderPixelFormat.bgra8Unorm.rawValue,
        ]
        let surface = TerminalRenderSurfaceHandle(
            surface: IOSurfaceCreate(properties as CFDictionary)!
        )
        let frameSequence = nextFrameSequence
        nextFrameSequence += 1
        surfaces[surface.identifier] = surface
        return RendererFrameLease(
            rendererEpoch: context.rendererEpoch,
            terminalID: context.attachment.terminalID,
            terminalEpoch: context.attachment.terminalEpoch,
            terminalSequence: terminalSequence,
            presentationID: context.attachment.presentationID,
            presentationGeneration: context.attachment.presentationGeneration,
            presentationSequence: presentationSequence,
            frameSequence: frameSequence,
            surfaceID: surface.identifier,
            width: context.attachment.width,
            height: context.attachment.height
        )
    }

    func publish(
        lease: RendererFrameLease,
        metadata: TerminalRenderFrameMetadata
    ) async throws -> RendererFramePublishDisposition {
        guard let surface = surfaces[lease.surfaceID] else {
            throw RendererPresentationEngineError.invariantViolation
        }
        switch try await sender.send(surface: surface, metadata: metadata) {
        case .sent:
            return .sent
        case .droppedQueueFull:
            return .droppedQueueFull
        }
    }

    func release(lease: RendererFrameLease) throws {
        guard surfaces.removeValue(forKey: lease.surfaceID) != nil else {
            throw RendererPresentationEngineError.invariantViolation
        }
        releasedLeases.append(lease)
    }

    func close() async throws {
        await sender.stop()
        closed = true
    }
}

private final class ManualAnimationScheduler:
    RendererAnimationScheduling,
    @unchecked Sendable
{
    private struct Entry: Sendable {
        let cancellation: ManualAnimationCancellation
        let operation: @Sendable () async -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.lazy.filter { !$0.cancellation.isCancelled }.count
    }

    func schedule(
        _ operation: @escaping @Sendable () async -> Void
    ) -> any RendererAnimationCancellation {
        let cancellation = ManualAnimationCancellation()
        lock.lock()
        entries.append(Entry(cancellation: cancellation, operation: operation))
        lock.unlock()
        return cancellation
    }

    func fireNext() async {
        guard let entry = popNext(), !entry.cancellation.isCancelled else { return }
        await entry.operation()
    }

    private func popNext() -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        let entry = entries.isEmpty ? nil : entries.removeFirst()
        return entry
    }
}

private final class ManualAnimationCancellation:
    RendererAnimationCancellation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
