@testable import CmuxNextRemoteView
import CoreGraphics
import CoreVideo
import QuartzCore
import Testing

/// Remote view presenter A presents off main (p03-rendering-114): a decoded frame is drawn and
/// presented on the render queue (`presentsWithTransaction = false`); main hears only of the first
/// frame after a start and of a new frame size, and `shownFrame` reads the mailbox with no hop.
/// Chrome's GPU thread presents the same way (gpu/ipc/service/image_transport_surface_overlay_mac.h).
@Suite(.serialized) struct LayerContentsPresenterOffMainTests {
    /// A decoder at 60 fps: 120 frames, the first 60 at one size, the rest at another. Each frame is
    /// presented after the one before it went on screen, so none is dropped.
    @Test(.timeLimit(.minutes(1))) func aFrameTakesNoMainTurnOnlyTheFirstAndASizeChangeDo() async throws {
        let presenter = try #require(LayerContentsPresenter(), "no Metal device here")
        var sizes: [CGSize] = []
        var shown = 0
        presenter.onFrameSize = { sizes.append($0) }
        presenter.onFrameShown = { shown += 1 }
        presenter.armFrameShown()

        for number in 0..<UInt32(120) {
            let frame = try #require(Self.frame(number, width: number < 60 ? 320 : 640, height: number < 60 ? 200 : 400))
            presenter.present(frame)
            try await Self.until("frame \(number) shows") { presenter.shownFrame?.frame == number }
        }
        try await Self.until("both sizes reached main") { sizes.count == 2 }
        await Self.settle()

        #expect(presenter.mainTurns == 2, "main turns \(presenter.mainTurns) for 120 frames and 2 sizes")
        #expect(sizes == [CGSize(width: 320, height: 200), CGSize(width: 640, height: 400)])
        #expect(shown == 2)
        #expect(presenter.discardedFrames == 0)
    }

    /// A pane that starts again arms the presenter: its next frame tells main once, a same-size one.
    @Test(.timeLimit(.minutes(1))) func aRestartHearsItsFirstFrameOnce() async throws {
        let presenter = try #require(LayerContentsPresenter(), "no Metal device here")
        var shown = 0
        presenter.onFrameShown = { shown += 1 }
        presenter.armFrameShown()
        let first = try #require(Self.frame(1))
        presenter.present(first)
        try await Self.until("the first frame shows") { shown == 1 }

        presenter.armFrameShown()
        for number in 2..<UInt32(10) {
            let frame = try #require(Self.frame(number))
            presenter.present(frame)
            try await Self.until("frame \(number) shows") { presenter.shownFrame?.frame == number }
        }
        await Self.settle()

        #expect(shown == 2)
        #expect(presenter.mainTurns == 2)
    }

    /// A pane torn down while frames are in flight: nothing crashes, the render queue holds the layer
    /// for its last draw, then the presenter and its layer go.
    @Test(.timeLimit(.minutes(1))) func aPresenterTornDownMidStreamFreesItsLayerAfterTheLastDraw() async throws {
        weak var layer: CALayer?
        weak var released: LayerContentsPresenter?
        do {
            // An explicit transaction: an implicit one would hold the layer until a run loop turn commits it.
            CATransaction.begin()
            let made = LayerContentsPresenter()
            CATransaction.commit()
            let presenter = try #require(made, "no Metal device here")
            layer = presenter.layer
            released = presenter
            for number in 0..<UInt32(30) {
                let frame = try #require(Self.frame(number))
                presenter.present(frame)
            }
        }
        try await Self.until("the presenter is gone") { released == nil }
        try await Self.until("the render queue let its layer go") { layer == nil }
    }

    // MARK: Helpers

    /// A decoded frame: an IOSurface-backed, Metal-compatible BGRA buffer.
    nonisolated static func frame(_ number: UInt32, width: Int = 320, height: Int = 200) -> RemoteDecodedFrame? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        // SAFETY: Core Video writes one +1 buffer to the local `buffer`, live for the call.
        guard unsafe CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        return RemoteDecodedFrame(pixelBuffer: buffer, frame: number, tCaptureMicros: 0, decodedAtNanos: 0)
    }

    /// Lets every main-actor job already posted run.
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<20 { await Task.yield() }
    }

    static func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
