import CoreGraphics
import Foundation
import QuartzCore
import Synchronization
import Testing
@testable import CmuxNextRemoteBrowser
import CmuxNextRemoteView

#if DEBUG
/// `RemoteBrowserPane.stop()` against a source that never stops sending:
/// once stop returns, no decoded frame reaches the presenter, and the source
/// sees that the pane stopped reading.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RemoteBrowserStopTests {
    @Test func noFrameReachesThePresenterAfterStopReturns() async throws {
        let keyframe = try #require(await Self.keyframe(), "no H.264 encoder on this Mac")
        // A decode in flight when stop() runs is the case under test; several
        // rounds make it certain that some stop lands mid-decode.
        for round in 0..<20 {
            let source = ContinuousStreamSource(keyframe: keyframe)
            let presenter = RecordingPresenter()
            let pane = RemoteBrowserPane(source: source, presenter: presenter)
            pane.start()
            try await Self.until { presenter.presented >= 2 }
            pane.stop()
            let atStop = presenter.presented
            try await Self.until { source.sawStop }
            // The pipeline asks the source for its next unit only after the
            // decode that was in flight finished, so every late frame has
            // been delivered by now.
            #expect(presenter.presented == atStop, "round \(round): \(presenter.presented - atStop) frame(s) after stop()")
            #expect(source.sawStop)
        }
    }

    /// One encoded H.264 keyframe, or nil without a VideoToolbox encoder.
    private static func keyframe() async -> RemoteAccessUnit? {
        let mock = MockRemoteStreamSource(width: 640, height: 360)
        guard mock.canEncode else { return nil }
        let units = mock.accessUnits()
        mock.damage()
        for await unit in units where unit.isKeyframe { return unit }
        return nil
    }

    private static func until(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "condition not met within 10 s")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// A host that sends a keyframe every 200 us until the viewer stops reading
/// (the access-unit stream terminates).
private nonisolated final class ContinuousStreamSource: RemoteViewStreamSource {
    private let keyframe: RemoteAccessUnit
    private let stopped = Mutex(false)

    init(keyframe: RemoteAccessUnit) {
        self.keyframe = keyframe
    }

    var sawStop: Bool { stopped.withLock { $0 } }

    func accessUnits() -> AsyncStream<RemoteAccessUnit> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteAccessUnit.self, bufferingPolicy: .bufferingNewest(8))
        continuation.onTermination = { [self] _ in stopped.withLock { $0 = true } }
        let keyframe = self.keyframe
        Task.detached {
            var unit = keyframe
            var frame: UInt32 = 0
            while true {
                unit.frame = frame
                if case .terminated = continuation.yield(unit) { return }
                frame &+= 1
                try? await Task.sleep(for: .microseconds(200))
            }
        }
        return stream
    }

    func statusUpdates() -> AsyncStream<RemoteViewStatus> {
        AsyncStream { $0.yield(RemoteViewStatus(path: .direct, rttMs: 1, state: .streaming)) }
    }

    func cursorUpdates() -> AsyncStream<RemoteCursorState> { AsyncStream { _ in } }
    func requestKeyframe() {}
}

/// Counts `present` calls; shows nothing.
@MainActor
private final class RecordingPresenter: RemoteFramePresenter {
    let kind = RemotePresenterKind.layerContents
    let layer = CALayer()
    var onFrameSize: ((CGSize) -> Void)?
    private nonisolated let count = Mutex(0)

    nonisolated var presented: Int { count.withLock { $0 } }
    nonisolated func present(_ frame: RemoteDecodedFrame) { count.withLock { $0 += 1 } }
    func setBackingScale(_ scale: CGFloat) {}
    nonisolated var discardedFrames: Int { 0 }
}
#endif
