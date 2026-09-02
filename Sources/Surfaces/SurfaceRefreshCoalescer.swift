import Foundation

/// Turns a burst of "something changed" signals into bounded re-reads without a timer:
/// a request marks the coalescer dirty; when no pass is in flight one starts now, and a
/// pass that finishes dirty runs exactly one follow-up. So a burst costs at most two
/// passes (one that started before the burst ended, one that sees everything after),
/// a session that never goes quiet is re-read after every pass instead of being starved
/// by a restarted delay, and no signal is ever coordinated through `Task.sleep`.
///
/// Main-actor bound like its callers (a provider is main-actor state); `perform` is the
/// pass itself and may take as long as a network round trip.
@MainActor
final class SurfaceRefreshCoalescer {
    private let perform: @MainActor () async -> Void
    private var loop: Task<Void, Never>?
    /// Identity of the loop that owns `loop`: a cancelled loop unwinding late must not
    /// clear the replacement a newer request started (two passes would then overlap).
    private var loopToken = UUID()
    private var dirty = false
    /// Passes started so far (tests read it; the provider does not).
    private(set) var passes = 0

    init(perform: @escaping @MainActor () async -> Void) {
        self.perform = perform
    }

    /// A pass is running right now.
    var isRunning: Bool { loop != nil }

    /// Ask for a re-read. Coalesces with any pass already queued behind the running one.
    func request() {
        dirty = true
        guard loop == nil else { return }
        let token = UUID()
        loopToken = token
        loop = Task { @MainActor [weak self] in
            defer {
                if let self, self.loopToken == token { self.loop = nil }
            }
            while let self, self.dirty, !Task.isCancelled {
                self.dirty = false
                self.passes += 1
                await self.perform()
            }
        }
    }

    /// Drop the queued follow-up and stop after the pass in flight. A request that
    /// arrives before the cancelled pass unwinds starts a fresh loop of its own.
    func cancel() {
        dirty = false
        loopToken = UUID()
        loop?.cancel()
        loop = nil
    }
}
