import Foundation
import Testing
@testable import CmuxSimulator

/// A capture fake that replays a fixed frame list, then idles until cancelled.
private struct ScriptedCaptureBackend: SimulatorDisplayCapturing {
    let frames: [SimulatorDisplayFrame]

    func frames(for udid: SimulatorDeviceUDID) -> AsyncStream<SimulatorDisplayFrame> {
        let frames = frames
        return AsyncStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            // Leave the stream open like a live backend; termination comes
            // from the consumer cancelling.
        }
    }
}

@MainActor
@Suite("SimulatorPaneModel")
struct SimulatorPaneModelTests {
    private static let frame = SimulatorDisplayFrame(imageData: Data("frame".utf8), sequence: 1)

    private func waitUntil(
        _ condition: @MainActor () async -> Bool
    ) async {
        // Yield-loop bounded by the test runner's own timeout; each lap only
        // suspends, so a satisfied condition resolves immediately.
        while !(await condition()) {
            await Task.yield()
        }
    }

    @Test func bootsResolvedDeviceAndStreamsFrames() async throws {
        let runner = RecordingSimctlRunner(responses: [
            .init(matching: ["list"], data: SimulatorFixtures.singleDevice(
                udid: SimulatorFixtures.shutdownUDID, state: "Shutdown"
            )),
            .init(matching: ["list"], data: SimulatorFixtures.singleDevice(
                udid: SimulatorFixtures.shutdownUDID, state: "Shutdown"
            )),
            .init(matching: ["boot"], data: Data()),
            .init(matching: ["bootstatus"], data: Data()),
            .init(matching: ["shutdown"], data: Data()),
        ])
        let model = SimulatorPaneModel(
            deviceQuery: "cmux-emu-test",
            runner: runner,
            captureBackend: ScriptedCaptureBackend(frames: [Self.frame])
        )
        model.start()
        await waitUntil { model.latestFrame != nil }

        #expect(model.phase == .streaming)
        #expect(model.ownership == .bootedByCmux)
        #expect(model.device?.udid.rawValue == SimulatorFixtures.shutdownUDID)
        #expect(model.latestFrame == Self.frame)

        model.closePane()
        #expect(model.phase == .stopped)
        await waitUntil {
            await runner.recordedInvocations.contains(["shutdown", SimulatorFixtures.shutdownUDID])
        }
    }

    @Test func attachedPaneNeverShutsDeviceDown() async throws {
        let runner = RecordingSimctlRunner(responses: [
            .init(matching: ["list"], data: SimulatorFixtures.singleDevice(
                udid: SimulatorFixtures.bootedUDID, state: "Booted"
            )),
            .init(matching: ["list"], data: SimulatorFixtures.singleDevice(
                udid: SimulatorFixtures.bootedUDID, state: "Booted"
            )),
        ])
        let model = SimulatorPaneModel(
            deviceQuery: SimulatorFixtures.bootedUDID,
            runner: runner,
            captureBackend: ScriptedCaptureBackend(frames: [Self.frame])
        )
        model.start()
        await waitUntil { model.latestFrame != nil }
        #expect(model.ownership == .attachedToRunningDevice)

        model.closePane()
        // Teardown is fire-and-forget; give it a beat, then assert nothing
        // lifecycle-mutating ran.
        await Task.yield()
        let invocations = await runner.recordedInvocations
        #expect(!invocations.contains(where: { $0.first == "shutdown" }))
        #expect(!invocations.contains(where: { $0.first == "boot" }))
    }

    @Test func unknownDeviceFailsWithDeviceNotFound() async throws {
        let runner = RecordingSimctlRunner(responses: [
            .init(matching: ["list"], data: SimulatorFixtures.singleDevice(
                udid: SimulatorFixtures.bootedUDID, state: "Booted"
            )),
        ])
        let model = SimulatorPaneModel(deviceQuery: "iPhone 42", runner: runner)
        model.start()
        await waitUntil { model.phase != .idle && model.phase != .resolvingDevice }
        #expect(model.phase == .failed(.deviceNotFound(query: "iPhone 42")))
    }
}
