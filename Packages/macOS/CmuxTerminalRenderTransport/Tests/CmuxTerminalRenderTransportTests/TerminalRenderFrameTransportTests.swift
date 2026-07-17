import Darwin
import Foundation
import Testing
import TerminalRenderMachIPCTestSupport
@testable import CmuxTerminalRenderProtocol
@testable import CmuxTerminalRenderTransport

@Suite(.serialized)
struct TerminalRenderFrameTransportTests {
    private let fixture = TerminalRenderTransportTestFixture()

    @Test
    func transfersIOSurfaceFromSeparateAuditAuthenticatedProcess() async throws {
        let metadata = try fixture.makeMetadata(frameSequence: 1)
        let receiver = try TerminalRenderFrameReceiver(
            initialFence: fixture.makeFence()
        )
        let executable = try #require(
            fixture.executableCandidates(named: "cmux-terminal-render-test-sender").first
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            receiver.endpoint.serviceName,
            receiver.endpoint.capability.base64EncodedString(),
            TerminalRenderFrameMetadataCodec().encode(metadata).base64EncodedString(),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let childWorker = try TerminalRenderWorkerIdentity(
            processID: process.processIdentifier,
            effectiveUserID: geteuid()
        )
        #expect(childWorker.processID != getpid())
        try await receiver.authorize(worker: childWorker)

        var receivedFrame: TerminalRenderFrame?
        for _ in 0..<20 where receivedFrame == nil {
            switch try await receiver.receive(timeoutMilliseconds: 250) {
            case .frame(let frame):
                receivedFrame = frame
            case .timedOut:
                continue
            case .dropped(let reason):
                Issue.record("Child frame was dropped: \(reason)")
            }
        }
        guard let frame = receivedFrame else {
            Issue.record("Expected frame from child process")
            return
        }
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(frame.metadata == metadata)
        #expect(frame.workerIdentity == childWorker)
    }

    @Test
    func transfersRealIOSurfaceWithCompleteAuthenticatedMetadata() async throws {
        let worker = try currentWorker()
        let damage = try TerminalRenderDamageBounds(x: 2, y: 3, width: 20, height: 10)
        let metadata = try fixture.makeMetadata(damageBounds: damage)
        let surface = fixture.makeSurface()
        let sourceSurfaceID = surface.identifier
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: worker,
            initialFence: fixture.makeFence()
        )
        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)

        #expect(try await sender.send(surface: surface, metadata: metadata) == .sent)
        let result = try await receiver.receive(timeoutMilliseconds: 250)
        guard case .frame(let frame) = result else {
            Issue.record("Expected an imported frame, got \(result)")
            return
        }
        #expect(frame.metadata == metadata)
        #expect(frame.workerIdentity == worker)
        #expect(frame.surface.identifier == sourceSurfaceID)
        #expect(frame.surface.width == 32)
        #expect(frame.surface.height == 24)
        #expect(frame.surface.pixelFormat == TerminalRenderPixelFormat.bgra8Unorm.rawValue)
    }

    @Test
    func rejectsWrongCapabilityWithoutImportingSurface() async throws {
        let worker = try currentWorker()
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: worker,
            initialFence: fixture.makeFence()
        )
        var wrongCapability = receiver.endpoint.capability
        wrongCapability[0] ^= 0xFF
        let wrongEndpoint = try TerminalRenderFrameEndpoint(
            serviceName: receiver.endpoint.serviceName,
            capability: wrongCapability
        )
        let sender = try TerminalRenderFrameSender(endpoint: wrongEndpoint)

        #expect(try await sender.send(
            surface: fixture.makeSurface(),
            metadata: fixture.makeMetadata()
        ) == .sent)
        guard case .dropped(.capabilityMismatch) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected capability rejection")
            return
        }
    }

    @Test
    func rejectsWrongAuditProcessID() async throws {
        let wrongWorker = try TerminalRenderWorkerIdentity(
            processID: getpid() + 1,
            effectiveUserID: geteuid()
        )
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: wrongWorker,
            initialFence: fixture.makeFence()
        )
        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)

        #expect(try await sender.send(
            surface: fixture.makeSurface(),
            metadata: fixture.makeMetadata()
        ) == .sent)
        guard case .dropped(.peerIdentityMismatch) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected PID audit-token rejection")
            return
        }
    }

    @Test
    func rejectsWrongAuditEffectiveUserID() async throws {
        let wrongWorker = try TerminalRenderWorkerIdentity(
            processID: getpid(),
            effectiveUserID: geteuid() &+ 1
        )
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: wrongWorker,
            initialFence: fixture.makeFence()
        )
        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)

        #expect(try await sender.send(
            surface: fixture.makeSurface(),
            metadata: fixture.makeMetadata()
        ) == .sent)
        guard case .dropped(.peerIdentityMismatch) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected effective-UID audit-token rejection")
            return
        }
    }

    @Test
    func fullQueueDropsNewestSendWithoutBlocking() async throws {
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: currentWorker(),
            initialFence: fixture.makeFence(),
            queueLimit: 1
        )
        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)
        let surface = fixture.makeSurface()

        #expect(try await sender.send(
            surface: surface,
            metadata: fixture.makeMetadata(frameSequence: 1)
        ) == .sent)
        #expect(try await sender.send(
            surface: surface,
            metadata: fixture.makeMetadata(frameSequence: 2)
        ) == .droppedQueueFull)

        guard case .frame(let frame) = try await receiver.receive(timeoutMilliseconds: 250) else {
            Issue.record("Expected the queued first frame")
            return
        }
        #expect(frame.metadata.frameSequence == 1)
    }

    @Test
    func oversizedMessageIsConsumedAndNextValidFrameIsReceivable() async throws {
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: currentWorker(),
            initialFence: fixture.makeFence()
        )
        let sendResult = receiver.endpoint.serviceName.withCString {
            cmux_terminal_render_test_send_oversized_message($0)
        }
        #expect(sendResult == KERN_SUCCESS)

        guard case .dropped(.malformedMachMessage) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected the oversized message to be consumed as malformed")
            return
        }

        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)
        #expect(try await sender.send(
            surface: fixture.makeSurface(),
            metadata: fixture.makeMetadata(frameSequence: 21)
        ) == .sent)
        guard case .frame(let frame) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected a valid frame after the oversized-message drop")
            return
        }
        #expect(frame.metadata.frameSequence == 21)
    }

    @Test
    func unexpectedComplexMessageIsDestroyedAndNextValidFrameIsReceivable() async throws {
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: currentWorker(),
            initialFence: fixture.makeFence()
        )
        let sendResult = receiver.endpoint.serviceName.withCString {
            cmux_terminal_render_test_send_unexpected_complex_message($0)
        }
        #expect(sendResult == KERN_SUCCESS)

        guard case .dropped(.malformedMachMessage) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected the unexpected complex message to be destroyed")
            return
        }

        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)
        #expect(try await sender.send(
            surface: fixture.makeSurface(),
            metadata: fixture.makeMetadata(frameSequence: 22)
        ) == .sent)
        guard case .frame(let frame) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected a valid frame after complex-message destruction")
            return
        }
        #expect(frame.metadata.frameSequence == 22)
    }

    @Test
    func staleDimensionsAndGenerationAreRejectedBeforeSurfaceImport() async throws {
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: currentWorker(),
            initialFence: fixture.makeFence()
        )
        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)

        #expect(try await sender.send(
            surface: fixture.makeSurface(width: 1, height: 1),
            metadata: fixture.makeMetadata(width: 31)
        ) == .sent)
        guard case .dropped(.stale(.dimensionsMismatch)) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected metadata dimensions rejection before descriptor import")
            return
        }

        #expect(try await sender.send(
            surface: fixture.makeSurface(width: 1, height: 1),
            metadata: fixture.makeMetadata(presentationGeneration: 12, frameSequence: 18)
        ) == .sent)
        guard case .dropped(.stale(.presentationGenerationMismatch)) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected generation rejection before descriptor import")
            return
        }
    }

    @Test
    func importedSurfaceDescriptorMustMatchAuthenticatedMetadata() async throws {
        let rgbaFence = try fixture.makeFence(pixelFormat: .rgba16Float)
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: currentWorker(),
            initialFence: rgbaFence
        )
        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)

        #expect(try await sender.send(
            surface: fixture.makeSurface(pixelFormat: .bgra8Unorm),
            metadata: fixture.makeMetadata(pixelFormat: .rgba16Float)
        ) == .sent)
        guard case .dropped(.surfaceDescriptorMismatch) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected imported IOSurface descriptor rejection")
            return
        }

        let bgraReceiver = try TerminalRenderFrameReceiver(
            expectedWorker: currentWorker(),
            initialFence: fixture.makeFence()
        )
        let bgraSender = try TerminalRenderFrameSender(endpoint: bgraReceiver.endpoint)
        #expect(try await bgraSender.send(
            surface: fixture.makeSurface(bytesPerElementOverride: 8),
            metadata: fixture.makeMetadata(frameSequence: 20)
        ) == .sent)
        guard case .dropped(.surfaceDescriptorMismatch) = try await bgraReceiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected bytes-per-element descriptor rejection")
            return
        }
        #expect(try await bgraSender.send(
            surface: fixture.makeSurface(),
            metadata: fixture.makeMetadata(frameSequence: 20)
        ) == .sent)
        guard case .frame(let recoveredFrame) = try await bgraReceiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected descriptor rejection not to advance frame sequence")
            return
        }
        #expect(recoveredFrame.metadata.frameSequence == 20)
    }

    @Test
    func fenceUpdateRejectsAlreadyQueuedOldGeneration() async throws {
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: currentWorker(),
            initialFence: fixture.makeFence()
        )
        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)

        #expect(try await sender.send(
            surface: fixture.makeSurface(),
            metadata: fixture.makeMetadata()
        ) == .sent)
        await receiver.updateFence(try fixture.makeFence(presentationGeneration: 14))

        guard case .dropped(.stale(.presentationGenerationMismatch)) = try await receiver.receive(
            timeoutMilliseconds: 250
        ) else {
            Issue.record("Expected old queued generation to be discarded")
            return
        }
    }

    @Test
    func timeoutCancellationAndExplicitTeardownAreBounded() async throws {
        let receiver = try TerminalRenderFrameReceiver(
            expectedWorker: currentWorker(),
            initialFence: fixture.makeFence()
        )
        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)

        guard case .timedOut = try await receiver.receive(timeoutMilliseconds: 0) else {
            Issue.record("Expected an immediate empty-queue timeout")
            return
        }
        await #expect(throws: TerminalRenderFrameTransportError.invalidReceiveTimeout) {
            try await receiver.receive(
                timeoutMilliseconds:
                    TerminalRenderFrameReceiver.maximumReceiveTimeoutMilliseconds + 1
            )
        }

        let receiveTask = Task {
            try await receiver.receive(timeoutMilliseconds: 250)
        }
        receiveTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await receiveTask.value
        }

        await sender.stop()
        await #expect(throws: TerminalRenderFrameTransportError.stopped) {
            try await sender.send(
                surface: fixture.makeSurface(),
                metadata: fixture.makeMetadata()
            )
        }

        await receiver.stop()
        await #expect(throws: TerminalRenderFrameTransportError.stopped) {
            try await receiver.receive(timeoutMilliseconds: 0)
        }

        let tornDownReceiver = try TerminalRenderFrameReceiver(
            expectedWorker: currentWorker(),
            initialFence: fixture.makeFence()
        )
        let orphanedSender = try TerminalRenderFrameSender(endpoint: tornDownReceiver.endpoint)
        await tornDownReceiver.stop()
        await #expect(throws: TerminalRenderFrameTransportError.self) {
            try await orphanedSender.send(
                surface: fixture.makeSurface(),
                metadata: fixture.makeMetadata()
            )
        }
    }

    @Test
    func authorizationIsRequiredAndWriteOnce() async throws {
        let receiver = try TerminalRenderFrameReceiver(
            initialFence: fixture.makeFence()
        )
        await #expect(throws: TerminalRenderFrameTransportError.workerNotAuthorized) {
            try await receiver.receive(timeoutMilliseconds: 0)
        }

        let worker = try currentWorker()
        try await receiver.authorize(worker: worker)
        try await receiver.authorize(worker: worker)
        let differentWorker = try TerminalRenderWorkerIdentity(
            processID: worker.processID + 1,
            effectiveUserID: worker.effectiveUserID
        )
        await #expect(throws: TerminalRenderFrameTransportError.workerAlreadyAuthorized) {
            try await receiver.authorize(worker: differentWorker)
        }
        #expect(await receiver.authorizedWorker() == worker)
    }

    @Test
    func queueAndTimeoutLimitsFailBeforeCreatingResources() throws {
        #expect(throws: TerminalRenderFrameTransportError.invalidQueueLimit) {
            try TerminalRenderFrameReceiver(
                expectedWorker: currentWorker(),
                initialFence: fixture.makeFence(),
                queueLimit: 0
            )
        }
        #expect(throws: TerminalRenderFrameTransportError.invalidQueueLimit) {
            try TerminalRenderFrameReceiver(
                expectedWorker: currentWorker(),
                initialFence: fixture.makeFence(),
                queueLimit: 65
            )
        }
    }

    private func currentWorker() throws -> TerminalRenderWorkerIdentity {
        try TerminalRenderWorkerIdentity(
            processID: getpid(),
            effectiveUserID: geteuid()
        )
    }
}
