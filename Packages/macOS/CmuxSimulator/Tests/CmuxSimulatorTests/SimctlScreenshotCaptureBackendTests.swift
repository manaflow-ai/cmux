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

/// A scripted single-capture source: replays results in order, then repeats
/// the last one.
private actor ScriptedScreenshotSource: SimulatorScreenshotCapturing {
    private var results: [Result<Data, SimctlCommandFailure>]
    private(set) var captureCount = 0

    init(results: [Result<Data, SimctlCommandFailure>]) {
        self.results = results
    }

    func captureScreenshot(of udid: SimulatorDeviceUDID) async throws -> Data {
        captureCount += 1
        let result = results.count > 1 ? results.removeFirst() : results[0]
        return try result.get()
    }
}

@Suite("SimctlScreenshotCaptureBackend")
struct SimctlScreenshotCaptureBackendTests {
    private let udid = SimulatorDeviceUDID(rawValue: SimulatorFixtures.bootedUDID)!

    @Test func streamsDeduplicatedScreenshotsAndSkipsFailures() async throws {
        let source = ScriptedScreenshotSource(results: [
            .success(Data("frame-a".utf8)),
            .success(Data("frame-a".utf8)),
            .failure(SimctlCommandFailure(
                arguments: ["io"], exitCode: 1, standardErrorText: "device still booting"
            )),
            .success(Data("frame-b".utf8)),
        ])
        let backend = SimctlScreenshotCaptureBackend(source: source, frameInterval: .milliseconds(1))

        var frames: [SimulatorDisplayFrame] = []
        for await frame in backend.frames(for: udid) {
            frames.append(frame)
            if frames.count == 2 { break }
        }

        #expect(frames.map(\.sequence) == [1, 2])
        #expect(frames.map(\.imageData) == [Data("frame-a".utf8), Data("frame-b".utf8)])
        #expect(await source.captureCount >= 4)
    }
}

@Suite("SimctlFileScreenshotSource")
struct SimctlFileScreenshotSourceTests {
    private let udid = SimulatorDeviceUDID(rawValue: SimulatorFixtures.bootedUDID)!

    /// A runner that plays simctl's part: writes PNG bytes at the path given
    /// as the screenshot command's final argument.
    private struct FileWritingRunner: SimctlCommandRunning {
        let payload: Data

        @discardableResult
        func run(_ arguments: [String]) async throws -> Data {
            guard let path = arguments.last else { return Data() }
            try payload.write(to: URL(fileURLWithPath: path))
            return Data()
        }
    }

    @Test func writesReadsAndCleansUpTemporaryCapture() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-simulator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let payload = Data("png-bytes".utf8)
        let source = SimctlFileScreenshotSource(
            runner: FileWritingRunner(payload: payload),
            temporaryDirectory: temporaryDirectory
        )
        let captured = try await source.captureScreenshot(of: udid)
        #expect(captured == payload)

        // The capture file must not be left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        #expect(leftovers.isEmpty)
    }

    @Test func capturePassesExplicitUDIDAndPNGType() async throws {
        let runner = RecordingSimctlRunner(responses: [])
        let source = SimctlFileScreenshotSource(runner: runner)
        // The recording runner has no canned response, so the capture throws;
        // the invocation shape is what this test pins.
        _ = try? await source.captureScreenshot(of: udid)
        let invocation = try #require(await runner.recordedInvocations.first)
        #expect(invocation.prefix(4) == ["io", udid.rawValue, "screenshot", "--type=png"])
        #expect(invocation.count == 5)
        #expect(invocation[4].hasSuffix(".png"))
        #expect(invocation[4] != "-")
    }
}
