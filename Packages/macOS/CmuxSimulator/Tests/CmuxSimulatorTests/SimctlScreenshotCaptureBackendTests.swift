import Foundation
import Testing
@testable import CmuxSimulator

@Suite("SimulatorFrameDeduplicator")
struct SimulatorFrameDeduplicatorTests {
    @Test func dropsEmptyAndRepeatedCapturesAndNumbersFrames() {
        var deduplicator = SimulatorFrameDeduplicator()
        #expect(deduplicator.frame(for: Data()) == nil)

        let first = deduplicator.frame(for: Data("frame-a".utf8))
        #expect(first?.sequence == 1)
        #expect(deduplicator.frame(for: Data("frame-a".utf8)) == nil)

        let second = deduplicator.frame(for: Data("frame-b".utf8))
        #expect(second?.sequence == 2)
        #expect(second?.imageData == Data("frame-b".utf8))

        // Returning to earlier content is a change and must yield again.
        let third = deduplicator.frame(for: Data("frame-a".utf8))
        #expect(third?.sequence == 3)
    }
}

@Suite("SimctlScreenshotCaptureBackend")
struct SimctlScreenshotCaptureBackendTests {
    private let udid = SimulatorDeviceUDID(rawValue: SimulatorFixtures.bootedUDID)!

    @Test func streamsDeduplicatedScreenshotsAndSkipsFailures() async throws {
        let runner = RecordingSimctlRunner(responses: [
            .init(matching: ["io"], data: Data("frame-a".utf8)),
            .init(matching: ["io"], data: Data("frame-a".utf8)),
            .init(matching: ["io"], failure: SimctlCommandFailure(
                arguments: ["io"], exitCode: 1, standardErrorText: "device still booting"
            )),
            .init(matching: ["io"], data: Data("frame-b".utf8)),
        ])
        let backend = SimctlScreenshotCaptureBackend(runner: runner, frameInterval: .milliseconds(1))

        var frames: [SimulatorDisplayFrame] = []
        for await frame in backend.frames(for: udid) {
            frames.append(frame)
            if frames.count == 2 { break }
        }

        #expect(frames.map(\.sequence) == [1, 2])
        #expect(frames.map(\.imageData) == [Data("frame-a".utf8), Data("frame-b".utf8)])

        let invocations = await runner.recordedInvocations
        #expect(invocations.allSatisfy { $0.starts(with: ["io", udid.rawValue, "screenshot"]) })
    }
}
