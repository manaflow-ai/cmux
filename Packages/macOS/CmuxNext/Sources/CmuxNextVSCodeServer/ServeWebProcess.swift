import Foundation

/// A real `serve-web` process and the pipe its output drains through.
final class ServeWebProcess: VSCodeServeWebProcessHandle {
    // Configured once before `run()`; afterwards only `isRunning` and `terminate()` are called,
    // which Foundation's Process allows from any thread.
    private nonisolated(unsafe) let process: Process // crash-allow: immutable let; after run() only isRunning and terminate(), which Process allows from any thread
    // Held so the output pipe stays open while the drain task reads it.
    private nonisolated(unsafe) let pipe: Pipe // crash-allow: immutable let, never read after init (it only keeps the pipe open)

    init(process: Process, pipe: Pipe) {
        self.process = process
        self.pipe = pipe
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
