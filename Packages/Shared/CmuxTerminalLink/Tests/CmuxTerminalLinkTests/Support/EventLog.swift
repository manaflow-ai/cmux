import CmuxLinkTesting
import CmuxTerminalRenderCore
import CmuxTerminalStream
import Foundation
import Testing

/// Drains a source's stream as the renderer would and lets tests wait for
/// events by shape. `.path` events are kept apart (they interleave freely).
final class EventLog: Sendable {
    let events = AsyncQueue<TerminalSourceEvent>()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<TerminalSourceEvent>) {
        let events = events
        task = Task {
            for await event in stream {
                if case .path = event { continue }
                await events.push(event)
            }
            await events.finish()
        }
    }

    deinit { task.cancel() }

    func next() async throws -> TerminalSourceEvent {
        try await within { try #require(await self.events.next()) }
    }

    /// Skips events until `match` returns a value.
    func next<T: Sendable>(_ match: @escaping @Sendable (TerminalSourceEvent) -> T?) async throws -> T {
        try await within {
            while let event = await self.events.next() {
                if let value = match(event) { return value }
            }
            throw TimeoutError()
        }
    }

    func frame(_ kind: TerminalFrame.Kind? = nil) async throws -> TerminalFrame {
        try await next { event in
            guard case .frame(let frame) = event, kind == nil || frame.kind == kind else { return nil }
            return frame
        }
    }

    func grid() async throws -> (cols: Int, rows: Int, generation: UInt32) {
        try await next { event in
            guard case .grid(let cols, let rows, let generation) = event else { return nil }
            return (cols, rows, generation)
        }
    }

    func closed() async throws -> String {
        try await next { event in
            guard case .closed(let reason) = event else { return nil }
            return reason
        }
    }
}
