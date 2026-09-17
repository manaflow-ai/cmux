import CMUXMobileCore
import CoreGraphics
import Foundation
import ImageIO

/// Decodes browser frame payloads away from the main actor and emits accepted frames.
actor BrowserStreamFrameDecoder {
    /// The accepted decoded-frame stream.
    nonisolated let frames: AsyncStream<BrowserStreamFrame>

    private let continuation: AsyncStream<BrowserStreamFrame>.Continuation
    private var sequencePolicy = BrowserStreamFrameSequencePolicy()
    private var generation: UInt64 = 0

    /// Creates a decoder and its frame stream.
    init() {
        let pair = AsyncStream<BrowserStreamFrame>.makeStream(bufferingPolicy: .bufferingNewest(2))
        frames = pair.stream
        continuation = pair.continuation
    }

    deinit {
        continuation.finish()
    }

    /// Starts an off-actor decode for a wire frame.
    /// - Parameter event: The frame event containing base64 image bytes.
    func submit(_ event: MobileBrowserFrameEvent) {
        let submittedGeneration = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let frame = Self.decode(event) else { return }
            await self?.accept(frame, generation: submittedGeneration)
        }
    }

    /// Resets subscription-local sequencing so a restarted stream may begin at one.
    func reset() {
        generation &+= 1
        sequencePolicy.reset()
    }

    private func accept(_ frame: BrowserStreamFrame, generation: UInt64) {
        guard generation == self.generation, sequencePolicy.accept(frame.sequence) else { return }
        continuation.yield(frame)
    }

    private nonisolated static func decode(_ event: MobileBrowserFrameEvent) -> BrowserStreamFrame? {
        guard event.pageWidth > 0, event.pageHeight > 0,
              event.pixelWidth > 0, event.pixelHeight > 0,
              event.format == .jpeg || event.format == .png,
              let data = Data(base64Encoded: event.dataBase64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return BrowserStreamFrame(
            sequence: event.sequence,
            image: image,
            pageSize: CGSize(width: event.pageWidth, height: event.pageHeight),
            pixelSize: CGSize(width: event.pixelWidth, height: event.pixelHeight)
        )
    }
}
