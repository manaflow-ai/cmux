import CmuxLinkTesting
import CmuxTerminalRenderCore
import CmuxTerminalStream
import Foundation
import Testing

/// Drains a terminal source like the renderer; `.path` events go apart.
final class SourceLog: Sendable {
    let events = AsyncQueue<TerminalSourceEvent>()
    let paths = AsyncQueue<TerminalPath>()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<TerminalSourceEvent>) {
        let events = events
        let paths = paths
        task = Task {
            for await event in stream {
                if case .path(let path, _) = event {
                    await paths.push(path)
                    continue
                }
                await events.push(event)
            }
            await events.finish()
        }
    }

    deinit { task.cancel() }

    func next<T: Sendable>(_ match: @escaping @Sendable (TerminalSourceEvent) -> T?) async throws -> T {
        try await within {
            while let event = await self.events.next() {
                if let value = match(event) { return value }
            }
            throw TimeoutError()
        }
    }

    func frame(_ kind: TerminalFrame.Kind) async throws -> TerminalFrame {
        try await next { event in
            guard case .frame(let frame) = event, frame.kind == kind else { return nil }
            return frame
        }
    }

    func grid() async throws -> (cols: Int, rows: Int, generation: UInt32) {
        try await next { event in
            guard case .grid(let cols, let rows, let generation) = event else { return nil }
            return (cols, rows, generation)
        }
    }
}
