import AppKit
import CmuxSimulator
import IOSurface
import Testing

@testable import CmuxSimulatorUI
@testable import CmuxSimulatorWorker

@Suite("Simulator frame surface lifecycle")
@MainActor
struct SimulatorRemoteSurfaceLifecycleTests {
    @Test("A static visible pane presents its first completed frame")
    func staticVisiblePanePresentsFirstCompletedFrame() async throws {
        let source = EmptySimulatorFrameSurfaceSource(snapshot: simulatorFrameSnapshot(
            pixel: 0xFF_12_34_56,
            sequence: 1
        ))
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { _ in source })
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        view.frame = root.bounds
        root.addSubview(view)

        view.update(
            frameTransport: simulatorFrameTransportDescriptor(49),
            display: simulatorTestDisplay,
            chrome: nil
        )

        try await waitUntil {
            simulatorFrameImageFirstPixel(view.frameLayer?.contents) == 0xFF_12_34_56
        }
        #expect(simulatorFrameImageFirstPixel(
            view.frameLayer?.contents
        ) == 0xFF_12_34_56)
    }

    @Test("An ordered-out host window stops polling for frames")
    func orderedOutWindowStopsPolling() async throws {
        let source = SequencedSimulatorFrameSurfaceSource(snapshot: simulatorFrameSnapshot(
            pixel: 0xFF_12_34_56,
            sequence: 1
        ))
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { _ in source })
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        view.frame = root.bounds
        root.addSubview(view)
        view.update(
            frameTransport: simulatorFrameTransportDescriptor(51),
            display: simulatorTestDisplay,
            chrome: nil
        )
        try await waitUntil {
            source.copyCount == 1
                && simulatorFrameImageFirstPixel(view.frameLayer?.contents) == 0xFF_12_34_56
        }

        source.publish(simulatorFrameSnapshot(
            pixel: 0xFF_65_43_21,
            sequence: 2
        ))
        try await Task.sleep(for: .milliseconds(100))

        #expect(!window.isVisible)
        #expect(source.copyCount == 1)
        withExtendedLifetime(window) {}
    }

    @Test("The frame layer never presents worker-shared IOSurfaces")
    func frameLayerPresentsOnlyHostOwnedImages() async throws {
        let input = try #require(IOSurfaceCreate([
            kIOSurfaceWidth: 2,
            kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ] as CFDictionary))
        let source = EmptySimulatorFrameSurfaceSource(
            latestFrame: (surface: input, sequence: 2)
        )
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { _ in source })

        view.update(
            frameTransport: simulatorFrameTransportDescriptor(40),
            display: SimulatorDisplayMetadata(
                width: 2,
                height: 2,
                orientation: .portrait,
                scale: 1
            ),
            chrome: nil
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline, !isCGImage(view.frameLayer?.contents) {
            view.renderLatestFrame()
            try await clock.sleep(for: .milliseconds(1))
        }

        #expect(isCGImage(view.frameLayer?.contents))
    }

    @Test("A blocked frame copy leaves MainActor responsive and coalesces to newest")
    func blockedCopyDoesNotBlockMainActor() async throws {
        let descriptor = simulatorFrameTransportDescriptor(43)
        let source = BlockingSimulatorFrameSurfaceSource(snapshot: simulatorFrameSnapshot(
            pixel: 0xFF_11_22_33,
            sequence: 1
        ))
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { _ in source })
        view.update(
            frameTransport: descriptor,
            display: simulatorTestDisplay,
            chrome: nil
        )
        view.renderLatestFrame()
        try await waitUntil { await source.hasStarted() }

        let heartbeat = await Task { @MainActor in true }.value
        #expect(heartbeat)
        await source.update(snapshot: simulatorFrameSnapshot(
            pixel: 0xFF_44_55_66,
            sequence: 1_001
        ))
        for _ in 0..<1_000 {
            view.renderLatestFrame()
            await Task.yield()
        }
        #expect(await source.copyCount() == 1)

        await source.release()
        try await waitUntil {
            view.renderLatestFrame()
            return simulatorFrameImageFirstPixel(
                view.frameLayer?.contents
            ) == 0xFF_44_55_66
        }
        #expect(await source.copyCount() == 2)
    }

    @Test("A completed frame copy presents without another display tick")
    func completedCopyPresentsImmediately() async throws {
        let source = BlockingSimulatorFrameSurfaceSource(snapshot: simulatorFrameSnapshot(
            pixel: 0xFF_77_88_99,
            sequence: 1
        ))
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { _ in source })
        view.update(
            frameTransport: simulatorFrameTransportDescriptor(50),
            display: simulatorTestDisplay,
            chrome: nil
        )
        try await waitUntil { await source.hasStarted() }

        await source.release()

        try await waitUntil {
            simulatorFrameImageFirstPixel(
                view.frameLayer?.contents
            ) == 0xFF_77_88_99
        }
        #expect(simulatorFrameImageFirstPixel(
            view.frameLayer?.contents
        ) == 0xFF_77_88_99)
    }

    @Test("Frame publication signals wake a static pipeline without display polling")
    func publicationSignalsWakeStaticPipeline() async throws {
        let source = SignaledSimulatorFrameSurfaceSource(snapshot: simulatorFrameSnapshot(
            pixel: 0xFF_12_34_56,
            sequence: 1
        ))
        var completionCount = 0
        let pipeline = SimulatorFramePresentationPipeline(
            source: source,
            presentationDidComplete: { completionCount += 1 }
        )
        defer { pipeline.invalidate() }

        _ = pipeline.displayTick()
        try await waitUntil { completionCount == 1 }
        #expect(pipeline.displayTick()?.sequence == 1)
        let staticAvailabilityChecks = source.availabilityCheckCount

        try await Task.sleep(for: .milliseconds(100))
        #expect(source.availabilityCheckCount == staticAvailabilityChecks)

        source.publish(simulatorFrameSnapshot(
            pixel: 0xFF_65_43_21,
            sequence: 2
        ))
        try await waitUntil { completionCount == 2 }

        #expect(pipeline.displayTick()?.sequence == 2)
    }

    @Test("A publication burst schedules bounded main-actor frame work")
    func publicationBurstCoalescesMainActorWork() async throws {
        let source = SignaledSimulatorFrameSurfaceSource(snapshot: simulatorFrameSnapshot(
            pixel: 0xFF_12_34_56,
            sequence: 1
        ))
        var completionCount = 0
        let pipeline = SimulatorFramePresentationPipeline(
            source: source,
            presentationDidComplete: { completionCount += 1 }
        )
        defer { pipeline.invalidate() }

        _ = pipeline.displayTick()
        try await waitUntil { completionCount == 1 }
        #expect(pipeline.displayTick()?.sequence == 1)
        let availabilityChecksBeforeBurst = source.availabilityCheckCount

        source.signalPublicationBurst(count: 1_000)
        try await Task.sleep(for: .milliseconds(100))

        #expect(source.availabilityCheckCount - availabilityChecksBeforeBurst <= 2)
    }

    @Test("A publication invalidating an in-flight copy retries the newest frame")
    func invalidatedCopyRetriesNewestPublication() async throws {
        let source = InvalidatingSignaledSimulatorFrameSurfaceSource(
            snapshot: simulatorFrameSnapshot(
                pixel: 0xFF_12_34_56,
                sequence: 1
            )
        )
        var completionCount = 0
        let pipeline = SimulatorFramePresentationPipeline(
            source: source,
            presentationDidComplete: { completionCount += 1 }
        )
        defer { pipeline.invalidate() }

        _ = pipeline.displayTick()
        try await waitUntil { source.hasStartedCopy }
        source.publish(simulatorFrameSnapshot(
            pixel: 0xFF_65_43_21,
            sequence: 2
        ))
        try await Task.sleep(for: .milliseconds(50))
        source.releaseCopy()
        try await waitUntil { completionCount == 1 }

        #expect(source.copyCount == 2)
        #expect(pipeline.displayTick()?.sequence == 2)
    }

    @Test("Worker frame publication wakes the host pipeline")
    func workerPublicationWakesHostPipeline() async throws {
        let surface = try #require(IOSurfaceCreate([
            kIOSurfaceWidth: 2,
            kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ] as CFDictionary))
        let ring = try SimulatorFramebufferSurfaceRing(width: 2, height: 2)
        defer { ring.releaseResources() }
        let source = try SimulatorFrameSurfaceSource(descriptor: ring.descriptor)
        var completionCount = 0
        let pipeline = SimulatorFramePresentationPipeline(
            source: source,
            presentationDidComplete: { completionCount += 1 }
        )
        defer { pipeline.invalidate() }

        _ = pipeline.displayTick()
        try ring.publish(surface)
        try await waitUntil { completionCount == 1 }

        #expect(pipeline.displayTick()?.sequence == 1)
    }

    @Test("Input motion flushes once without a persistent presentation timer")
    func inputMotionUsesOneShotFlush() async throws {
        let view = SimulatorRemoteSurfaceView()
        defer { view.teardown() }
        var received: [SimulatorPointerEvent] = []
        view.onMessage = { message in
            guard case let .pointer(event) = message else { return }
            received.append(event)
        }
        let first = SimulatorPointerEvent(
            phase: .moved,
            primary: SimulatorPoint(x: 0.1, y: 0.2)
        )
        let last = SimulatorPointerEvent(
            phase: .moved,
            primary: SimulatorPoint(x: 0.8, y: 0.9)
        )

        view.send([.pointer(first), .pointer(last)])
        #expect(received.isEmpty)
        try await waitUntil { received.count == 1 }

        #expect(received == [last])
    }

    @Test("Frame polling follows the host display cadence")
    func framePollingFollowsDisplayCadence() {
        #expect(SimulatorRemoteSurfaceView.presentationTimerIntervalNanoseconds(
            maximumFramesPerSecond: nil
        ) == 16_666_667)
        #expect(SimulatorRemoteSurfaceView.presentationTimerIntervalNanoseconds(
            maximumFramesPerSecond: 60
        ) == 16_666_667)
        #expect(SimulatorRemoteSurfaceView.presentationTimerIntervalNanoseconds(
            maximumFramesPerSecond: 120
        ) == 8_333_333)
        #expect(SimulatorRemoteSurfaceView.presentationTimerIntervalNanoseconds(
            maximumFramesPerSecond: 240
        ) == 8_333_333)
    }

    @Test("A released stale copy cannot replace a newer transport frame")
    func replacementRejectsStaleCopyCompletion() async throws {
        let oldDescriptor = simulatorFrameTransportDescriptor(44)
        let newDescriptor = simulatorFrameTransportDescriptor(45)
        let oldSource = BlockingSimulatorFrameSurfaceSource(snapshot: simulatorFrameSnapshot(
            pixel: 0xFF_AA_00_00,
            sequence: 1
        ))
        let newSource = EmptySimulatorFrameSurfaceSource(snapshot: simulatorFrameSnapshot(
            pixel: 0xFF_00_BB_00,
            sequence: 1
        ))
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: {
            descriptor -> any SimulatorFrameSurfaceReading in
            if descriptor == oldDescriptor { return oldSource }
            return newSource
        })
        view.update(
            frameTransport: oldDescriptor,
            display: simulatorTestDisplay,
            chrome: nil
        )
        view.renderLatestFrame()
        try await waitUntil { await oldSource.hasStarted() }

        view.update(
            frameTransport: newDescriptor,
            display: simulatorTestDisplay,
            chrome: nil
        )
        try await waitUntil {
            view.renderLatestFrame()
            return simulatorFrameImageFirstPixel(
                view.frameLayer?.contents
            ) == 0xFF_00_BB_00
        }
        await oldSource.release()
        for _ in 0..<100 {
            view.renderLatestFrame()
            await Task.yield()
        }
        #expect(simulatorFrameImageFirstPixel(
            view.frameLayer?.contents
        ) == 0xFF_00_BB_00)
    }

    @Test("A released copy cannot restore a torn-down frame layer")
    func teardownRejectsStaleCopyCompletion() async throws {
        let source = BlockingSimulatorFrameSurfaceSource(snapshot: simulatorFrameSnapshot(
            pixel: 0xFF_CC_DD_EE,
            sequence: 1
        ))
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { _ in source })
        view.update(
            frameTransport: simulatorFrameTransportDescriptor(46),
            display: simulatorTestDisplay,
            chrome: nil
        )
        view.renderLatestFrame()
        try await waitUntil { await source.hasStarted() }

        view.teardown()
        await source.release()
        for _ in 0..<100 { await Task.yield() }

        #expect(view.frameLayer == nil)
    }

    @Test("Dismantling drops retained frame surfaces and rejects late updates")
    func dismantleIsTerminalForViewInstance() throws {
        let firstDescriptor = simulatorFrameTransportDescriptor(41)
        let secondDescriptor = simulatorFrameTransportDescriptor(42)
        var requestedDescriptors: [SimulatorFrameTransportDescriptor] = []
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { descriptor in
            requestedDescriptors.append(descriptor)
            return EmptySimulatorFrameSurfaceSource()
        })
        let display = SimulatorDisplayMetadata(
            width: 390,
            height: 844,
            orientation: .portrait,
            scale: 3
        )
        view.update(frameTransport: firstDescriptor, display: display, chrome: nil)
        let firstFrameLayer = try #require(view.frameLayer)

        #expect(requestedDescriptors == [firstDescriptor])
        #expect(firstFrameLayer.superlayer === view.layer)

        view.teardown()

        #expect(view.frameLayer == nil)
        #expect(firstFrameLayer.superlayer == nil)
        #expect(view.display == nil)
        #expect(view.onMessage == nil)

        view.update(frameTransport: secondDescriptor, display: display, chrome: nil)

        #expect(requestedDescriptors == [firstDescriptor])
        #expect(view.frameLayer == nil)
        #expect(view.display == nil)
    }

    @Test("Temporary window detachment preserves a reusable surface")
    func temporaryWindowDetachmentIsNotTerminal() throws {
        let firstDescriptor = simulatorFrameTransportDescriptor(47)
        let secondDescriptor = simulatorFrameTransportDescriptor(48)
        var requestedDescriptors: [SimulatorFrameTransportDescriptor] = []
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { descriptor in
            requestedDescriptors.append(descriptor)
            return EmptySimulatorFrameSurfaceSource()
        })
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        root.addSubview(view)
        view.update(frameTransport: firstDescriptor, display: simulatorTestDisplay, chrome: nil)

        view.removeFromSuperview()
        root.addSubview(view)
        view.update(frameTransport: secondDescriptor, display: simulatorTestDisplay, chrome: nil)

        #expect(requestedDescriptors == [firstDescriptor, secondDescriptor])
        #expect(view.frameLayer?.superlayer === view.layer)
    }

    @Test("A replacement view can retain a recovered worker frame ring")
    func replacementViewHostsRecoveredContext() throws {
        let firstDescriptor = simulatorFrameTransportDescriptor(7)
        let secondDescriptor = simulatorFrameTransportDescriptor(8)
        var requestedDescriptors: [SimulatorFrameTransportDescriptor] = []
        let original = SimulatorRemoteSurfaceView(frameSourceFactory: { descriptor in
            requestedDescriptors.append(descriptor)
            return EmptySimulatorFrameSurfaceSource()
        })
        let replacement = SimulatorRemoteSurfaceView(frameSourceFactory: { descriptor in
            requestedDescriptors.append(descriptor)
            return EmptySimulatorFrameSurfaceSource()
        })
        let display = SimulatorDisplayMetadata(
            width: 1_024,
            height: 1_366,
            orientation: .portrait,
            scale: 2
        )

        original.update(frameTransport: firstDescriptor, display: display, chrome: nil)
        original.teardown()
        replacement.update(frameTransport: secondDescriptor, display: display, chrome: nil)

        #expect(requestedDescriptors == [firstDescriptor, secondDescriptor])
        #expect(original.frameLayer == nil)
        #expect(replacement.frameLayer != nil)
    }

    @Test("A rejected replacement descriptor preserves the last host-owned frame layer")
    func rejectedReplacementPreservesCurrentLayer() throws {
        let firstDescriptor = simulatorFrameTransportDescriptor(15)
        let rejectedDescriptor = simulatorFrameTransportDescriptor(16)
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { descriptor in
            guard descriptor != rejectedDescriptor else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return EmptySimulatorFrameSurfaceSource()
        })
        let display = SimulatorDisplayMetadata(
            width: 390,
            height: 844,
            orientation: .portrait,
            scale: 3
        )
        view.update(frameTransport: firstDescriptor, display: display, chrome: nil)
        let firstLayer = try #require(view.frameLayer)

        view.update(frameTransport: rejectedDescriptor, display: display, chrome: nil)

        #expect(view.frameLayer === firstLayer)
    }

    @Test("Representable lifetime teardown breaks display and surface ownership")
    func representableLifetimeTearsDownView() throws {
        let descriptor = simulatorFrameTransportDescriptor(20)
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { _ in
            EmptySimulatorFrameSurfaceSource()
        })
        view.update(
            frameTransport: descriptor,
            display: SimulatorDisplayMetadata(
                width: 390,
                height: 844,
                orientation: .portrait,
                scale: 3
            ),
            chrome: nil
        )
        let frameLayer = try #require(view.frameLayer)
        var lifetime: SimulatorRemoteSurfaceLifetime? = SimulatorRemoteSurfaceLifetime()
        lifetime?.view = view

        lifetime = nil

        #expect(view.frameLayer == nil)
        #expect(frameLayer.superlayer == nil)
    }

    @Test("A frame transport mapping failure is surfaced for recovery")
    func mappingFailureIsReported() {
        let descriptor = simulatorFrameTransportDescriptor(21)
        let view = SimulatorRemoteSurfaceView(frameSourceFactory: { _ in
            throw CocoaError(.fileReadCorruptFile)
        })
        var receivedDescriptor: SimulatorFrameTransportDescriptor?
        var receivedFailure: SimulatorFailure?
        view.onFrameTransportFailure = { descriptor, failure in
            receivedDescriptor = descriptor
            receivedFailure = failure
        }

        view.update(
            frameTransport: descriptor,
            display: SimulatorDisplayMetadata(
                width: 390,
                height: 844,
                orientation: .portrait,
                scale: 3
            ),
            chrome: nil
        )

        #expect(receivedDescriptor == descriptor)
        #expect(receivedFailure?.code == "framebuffer_unavailable")
        #expect(view.frameLayer == nil)
    }

    private func isCGImage(_ value: Any?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value as CFTypeRef) == CGImage.typeID
    }

    private var simulatorTestDisplay: SimulatorDisplayMetadata {
        SimulatorDisplayMetadata(
            width: 2,
            height: 2,
            orientation: .portrait,
            scale: 1
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await condition() { return }
            try await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Condition did not become true before the deadline")
    }
}

private final class SequencedSimulatorFrameSurfaceSource:
    SimulatorFrameSurfaceReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshot: SimulatorFrameSnapshot
    private var copies = 0

    init(snapshot: SimulatorFrameSnapshot) {
        self.snapshot = snapshot
    }

    var copyCount: Int {
        lock.withLock { copies }
    }

    func publish(_ snapshot: SimulatorFrameSnapshot) {
        lock.withLock { self.snapshot = snapshot }
    }

    func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        lock.withLock {
            sequence.map { snapshot.sequence > $0 } ?? true
        }
    }

    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot? {
        lock.withLock {
            guard sequence.map({ snapshot.sequence > $0 }) ?? true else { return nil }
            copies += 1
            return snapshot
        }
    }
}

private final class SignaledSimulatorFrameSurfaceSource:
    SimulatorFrameSurfaceReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshot: SimulatorFrameSnapshot
    private var publicationHandler: (@Sendable () -> Void)?
    private var availabilityChecks = 0

    init(snapshot: SimulatorFrameSnapshot) {
        self.snapshot = snapshot
    }

    var availabilityCheckCount: Int {
        lock.withLock { availabilityChecks }
    }

    @discardableResult
    func setFramePublicationHandler(
        _ handler: (@Sendable () -> Void)?
    ) -> Bool {
        lock.withLock { publicationHandler = handler }
        return true
    }

    func publish(_ snapshot: SimulatorFrameSnapshot) {
        let handler = lock.withLock {
            self.snapshot = snapshot
            return publicationHandler
        }
        handler?()
    }

    func signalPublicationBurst(count: Int) {
        let handler = lock.withLock { publicationHandler }
        for _ in 0..<count {
            handler?()
        }
    }

    func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        lock.withLock {
            availabilityChecks += 1
            return sequence.map { snapshot.sequence > $0 } ?? true
        }
    }

    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot? {
        lock.withLock {
            guard sequence.map({ snapshot.sequence > $0 }) ?? true else { return nil }
            return snapshot
        }
    }
}

private final class InvalidatingSignaledSimulatorFrameSurfaceSource:
    SimulatorFrameSurfaceReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshot: SimulatorFrameSnapshot
    private var publicationHandler: (@Sendable () -> Void)?
    private var copies = 0
    private var copyStarted = false
    private var copyIsBlocked = true
    private var copyWaiters: [CheckedContinuation<Void, Never>] = []

    init(snapshot: SimulatorFrameSnapshot) {
        self.snapshot = snapshot
    }

    var copyCount: Int {
        lock.withLock { copies }
    }

    var hasStartedCopy: Bool {
        lock.withLock { copyStarted }
    }

    @discardableResult
    func setFramePublicationHandler(
        _ handler: (@Sendable () -> Void)?
    ) -> Bool {
        lock.withLock { publicationHandler = handler }
        return true
    }

    func publish(_ snapshot: SimulatorFrameSnapshot) {
        let handler = lock.withLock {
            self.snapshot = snapshot
            return publicationHandler
        }
        handler?()
    }

    func releaseCopy() {
        let waiters = lock.withLock {
            copyIsBlocked = false
            let waiters = copyWaiters
            copyWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        lock.withLock {
            sequence.map { snapshot.sequence > $0 } ?? true
        }
    }

    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot? {
        let copiedSequence = lock.withLock {
            copies += 1
            copyStarted = true
            return snapshot.sequence
        }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard copyIsBlocked else { return true }
                copyWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
        return lock.withLock {
            guard snapshot.sequence == copiedSequence,
                  sequence.map({ copiedSequence > $0 }) ?? true else {
                return nil
            }
            return snapshot
        }
    }
}
