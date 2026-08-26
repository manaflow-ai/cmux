import CmuxTerminalCore
import Foundation

/// Provides one bounded async handoff from a synchronous PTY callback to MainActor.
final class TerminalCapturedLinkForwarder: Sendable {
    private let continuation: AsyncStream<TerminalCapturedLinkForwardRequest>.Continuation
    private let drainTask: Task<Void, Never>

    init(
        workspaceID: UUID,
        surfaceID: UUID,
        ingress: TerminalLinkCaptureIngress,
        maximumBufferedLinks: Int = 512
    ) {
        let pipe = AsyncStream<TerminalCapturedLinkForwardRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(maximumBufferedLinks)
        )
        self.continuation = pipe.continuation
        self.drainTask = Task {
            for await request in pipe.stream {
                if Task.isCancelled { break }
                await ingress.ingest(
                    [request.link],
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
        for link in links {
            continuation.yield(TerminalCapturedLinkForwardRequest(
                link: link,
                settings: settings
            ))
        }
    }

    func finish() {
        continuation.finish()
        drainTask.cancel()
    }
}
