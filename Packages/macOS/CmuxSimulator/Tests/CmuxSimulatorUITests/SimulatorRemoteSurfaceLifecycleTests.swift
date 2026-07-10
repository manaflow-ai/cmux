import AppKit
import CmuxSimulator
import Testing

@testable import CmuxSimulatorUI

@Suite("Simulator frame surface lifecycle")
@MainActor
struct SimulatorRemoteSurfaceLifecycleTests {
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
}
