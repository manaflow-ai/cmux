import Darwin
import Dispatch

/// The seam adapter for ``ChiefBrainWatch``'s kernel exit event of one host process: a process
/// source on the main queue whose handler runs on the main actor in the source's own callout, with
/// no second hop (the arch rule's adapter for `MainActor.assumeIsolated`).
@MainActor
final class ChiefBrainExitSource {
    private let source: any DispatchSourceProcess

    init(pid: pid_t, onExit: @escaping @MainActor (pid_t) -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            // main-proof: the source's queue is DispatchQueue.main, whose handlers run on the main thread.
            MainActor.assumeIsolated { onExit(pid) }
        }
        self.source = source
        source.resume()
    }

    func cancel() { source.cancel() }
}
