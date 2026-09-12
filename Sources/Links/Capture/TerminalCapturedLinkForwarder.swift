import CmuxTerminalCore
import Foundation

/// Provides one bounded async handoff from a synchronous PTY callback to MainActor.
final class TerminalCapturedLinkForwarder: Sendable {
    private static let maximumLinksPerBatch = 32

    private let continuation: AsyncStream<TerminalCapturedLinkForwardRequest>.Continuation
    private let drainTask: Task<Void, Never>
    private let maximumLinksPerBatch: Int

    init(
        workspaceID: UUID,
        surfaceID: UUID,
        ingress: TerminalLinkCaptureIngress,
        maximumBufferedLinks: Int = 512
    ) {
        let boundedLinkCount = max(1, maximumBufferedLinks)
        let maximumLinksPerBatch = min(Self.maximumLinksPerBatch, boundedLinkCount)
        let maximumBufferedBatches = max(
            1,
            (boundedLinkCount + maximumLinksPerBatch - 1) / maximumLinksPerBatch
        )
        let pipe = AsyncStream<TerminalCapturedLinkForwardRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(maximumBufferedBatches)
        )
        self.maximumLinksPerBatch = maximumLinksPerBatch
        self.continuation = pipe.continuation
        self.drainTask = Task {
            for await request in pipe.stream {
                if Task.isCancelled { break }
                await ingress.ingest(
                    request.links,
                    workspaceID: workspaceID,
                    sourcePanelId: surfaceID,
                    settings: request.settings
                )
            }
        }
    }

    deinit {
        continuation.finish()
        drainTask.cancel()
    }

    func enqueue(
        _ links: [TerminalCapturedLink],
        settings: LinkCaptureSettingsSnapshot
    ) {
        for startIndex in stride(from: 0, to: links.count, by: maximumLinksPerBatch) {
            let endIndex = min(startIndex + maximumLinksPerBatch, links.count)
            continuation.yield(TerminalCapturedLinkForwardRequest(
                links: Array(links[startIndex..<endIndex]),
                settings: settings
            ))
        }
    }

    func finish() {
        continuation.finish()
        drainTask.cancel()
    }
}
