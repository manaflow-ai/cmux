import CmuxSimulator
import Darwin
import Foundation
import IOSurface
import Testing

@testable import CmuxSimulatorWorker

@Suite("Simulator framebuffer port discovery")
@MainActor
struct SimulatorFramebufferPortDiscoveryTests {
    @Test("Framebuffer discovery uses the current ioPorts contract")
    func currentIOPortsContract() async throws {
        let fixture = SimulatorFramebufferPortFixture()
        var transport: SimulatorFrameTransportDescriptor?
        var metadata: SimulatorDisplayMetadata?
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { transport = $0 },
            onDisplayChange: { metadata = $0 }
        )

        try await framebuffer.start(device: fixture.device)

        #expect(fixture.didRequestCurrentPorts)
        #expect(transport?.width == 8)
        #expect(transport?.height == 12)
        #expect(metadata?.width == 8)
        #expect(metadata?.height == 12)
    }

    @Test("Display identity may be published by callback registration")
    func callbackRegistrationPublishesDisplayIdentity() async throws {
        let fixture = SimulatorFramebufferPortFixture(
            propertiesAvailableAfterRegistration: true
        )
        var metadata: SimulatorDisplayMetadata?
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { _ in },
            onDisplayChange: { metadata = $0 }
        )

        try await framebuffer.start(device: fixture.device)

        #expect(metadata?.width == 8)
        #expect(metadata?.height == 12)
    }

    @Test("The current SimulatorKit default-screen flag identifies the built-in display")
    func currentDefaultScreenContract() async throws {
        let fixture = SimulatorFramebufferPortFixture(
            displays: [
                (screenID: 42, screenType: 0, width: 8, height: 12),
                (screenID: 1, screenType: 1, width: 30, height: 20),
            ],
            usesDefaultScreenFlag: true
        )
        var metadata: SimulatorDisplayMetadata?
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { _ in },
            onDisplayChange: { metadata = $0 }
        )

        try await framebuffer.start(device: fixture.device)

        #expect(metadata?.width == 8)
        #expect(metadata?.height == 12)
    }

    @Test("Screen identity may be exposed through an Objective-C forwarding proxy")
    func forwardingScreenPropertiesContract() async throws {
        let fixture = SimulatorFramebufferPortFixture(
            usesForwardingScreenProperties: true
        )
        var metadata: SimulatorDisplayMetadata?
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { _ in },
            onDisplayChange: { metadata = $0 }
        )

        try await framebuffer.start(device: fixture.device)

        #expect(metadata?.width == 8)
        #expect(metadata?.height == 12)
    }

    @Test("The built-in display wins over a larger external display")
    func primaryDisplayIdentityWins() async throws {
        let fixture = SimulatorFramebufferPortFixture(displays: [
            (screenID: 42, screenType: 0, width: 8, height: 12),
            (screenID: 1, screenType: 1, width: 30, height: 20),
        ])
        var metadata: SimulatorDisplayMetadata?
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { _ in },
            onDisplayChange: { metadata = $0 }
        )

        try await framebuffer.start(device: fixture.device)

        #expect(metadata?.width == 8)
        #expect(metadata?.height == 12)
    }

    @Test("Frame callbacks reuse the cached integrated display")
    func frameCallbacksReuseIntegratedDisplay() async throws {
        let fixture = SimulatorFramebufferPortFixture(displays: [
            (screenID: 42, screenType: 0, width: 8, height: 12),
            (screenID: 1, screenType: 1, width: 30, height: 20),
        ])
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { _ in },
            onDisplayChange: { _ in }
        )
        try await framebuffer.start(device: fixture.device)
        let readsAfterDiscovery = fixture.screenPropertiesReadCount

        for _ in 0..<20 { fixture.publishFrame(width: 8, height: 12) }

        #expect(fixture.screenPropertiesReadCount == readsAfterDiscovery)
    }

    @Test("Auxiliary display property changes preserve built-in orientation")
    func auxiliaryOrientationIsIgnored() async throws {
        let fixture = SimulatorFramebufferPortFixture(displays: [
            (screenID: 42, screenType: 0, width: 8, height: 12),
            (screenID: 1, screenType: 1, width: 30, height: 20),
        ])
        var metadata: [SimulatorDisplayMetadata] = []
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { _ in },
            onDisplayChange: { metadata.append($0) }
        )
        try await framebuffer.start(device: fixture.device)

        framebuffer.setOrientation(.landscapeRight)
        fixture.publishOrientation(3, displayIndex: 1)
        #expect(metadata.last?.orientation == .landscapeRight)

        fixture.publishOrientation(2, displayIndex: 0)
        #expect(metadata.last?.orientation == .portraitUpsideDown)
    }

    @Test("Stopping rejects a dimension change already waiting to publish")
    func stoppedFramebufferRejectsLateTransport() async throws {
        let fixture = SimulatorFramebufferPortFixture()
        let gate = SimulatorFrameTransportPublicationGate()
        var transports: [SimulatorFrameTransportDescriptor] = []
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { transports.append($0) },
            onDisplayChange: { _ in },
            beforeFrameTransportChange: { await gate.wait() },
            afterFrameTransportChange: { await gate.completeAttempt() }
        )
        try await framebuffer.start(device: fixture.device)

        fixture.publishFrame(width: 12, height: 18)
        try await gate.waitUntilBlocked()
        framebuffer.stop()
        await gate.release()
        try await gate.waitUntilAttemptCompleted()

        #expect(transports.count == 1)
        #expect(transports.first?.width == 8)
        #expect(transports.first?.height == 12)
    }

    @Test("Replacing geometry keeps the obsolete ring name available to the host")
    func resizeKeepsObsoleteFrameRingAvailable() async throws {
        let fixture = SimulatorFramebufferPortFixture()
        var transports: [SimulatorFrameTransportDescriptor] = []
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { transports.append($0) },
            onDisplayChange: { _ in }
        )
        try await framebuffer.start(device: fixture.device)
        let obsoleteName = try #require(transports.first?.sharedMemoryName)

        framebuffer.setTargetGeometry(SimulatorSurfaceGeometry(width: 4, height: 6, scale: 1))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while transports.count < 2, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(1))
        }

        #expect(transports.count == 2)
        let obsoleteHandle = try simulatorOpenSharedMemory(named: obsoleteName, flags: O_RDONLY)
        if obsoleteHandle >= 0 { close(obsoleteHandle) }
        #expect(obsoleteHandle >= 0)
        framebuffer.stop()
        let cleanupDeadline = clock.now.advanced(by: .seconds(2))
        var retiredHandle = try simulatorOpenSharedMemory(named: obsoleteName, flags: O_RDONLY)
        while retiredHandle >= 0, clock.now < cleanupDeadline {
            close(retiredHandle)
            await Task.yield()
            retiredHandle = try simulatorOpenSharedMemory(named: obsoleteName, flags: O_RDONLY)
        }
        if retiredHandle >= 0 { close(retiredHandle) }
        #expect(retiredHandle == -1)
    }

    @Test("A failed publication resume remains retryable")
    func failedResumeCanRetry() async throws {
        let fixture = SimulatorFramebufferPortFixture()
        var transports: [SimulatorFrameTransportDescriptor] = []
        let framebuffer = SimulatorFramebuffer(
            onFrameTransportChange: { transports.append($0) },
            onDisplayChange: { _ in }
        )
        try await framebuffer.start(device: fixture.device)
        try await framebuffer.setPublishingEnabled(false)
        fixture.removeSurface()

        await #expect(throws: SimulatorWorkerFailure.self) {
            try await framebuffer.setPublishingEnabled(true)
        }

        fixture.publishFrame(width: 8, height: 12)
        try await framebuffer.setPublishingEnabled(true)
        #expect(transports.count == 2)
    }
}
