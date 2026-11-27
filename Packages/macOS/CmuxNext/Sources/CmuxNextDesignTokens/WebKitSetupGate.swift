public import CmuxNextWakeups
package import Darwin
public import Foundation

/// Whether WebKit's setup answers on this host, asked off the main thread before a web view is
/// made where nobody waits for it (the New Tab spare). A WKWebView's first load issues sandbox
/// extensions and registers the user's fonts on the main thread; with a wedged sandboxd that held
/// launch for more than 10 s (cua-2, 2026-10-14). Unknown until ``probe(answered:)``; ready when the
/// sandbox broker answered; slow when it did not answer within ``timeout``, or a caller saw a web
/// view hold the main thread (``markSlow()``).
///
/// Slow is not for the run: after ``recheck`` (doubled for each later slow mark, up to ten minutes) the
/// setup is asked again, and an answer makes the gate ready and runs the last caller's `answered`, so
/// the New Tab pool warms again. On a Mac at load 250 one spare took over a second once, and a gate
/// that stayed slow left every later Cmd-T and Cmd-N to load its page cold (2026-11-10). A request
/// that never returned (a wedged sandboxd) holds its thread: no second probe starts while it hangs.
@MainActor public final class WebKitSetupGate {
    public enum State: Sendable { case unknown, probing, ready, slow }
    public private(set) var state = State.unknown
    public nonisolated static let timeout: Duration = .seconds(2)
    /// How long the first slow mark waits before the setup is asked again.
    public nonisolated static let recheck: Duration = .seconds(30)
    /// The longest wait before asking again, however often the setup was slow.
    public nonisolated static let longestRecheck: Duration = .seconds(600)
    /// The blocking request, run on a thread of its own; tests put a wedged one in its place.
    public var request: @Sendable () -> Void = WebKitSetupGate.issueSandboxExtension
    private let timer: DemandTimer
    private let rechecks: DemandTimer
    /// A probe's request has not returned yet (a wedged one never does).
    private var inFlight = false
    /// The slow marks so far: each doubles the next wait.
    private var slowMarks = 0
    /// The last caller's work once the setup answers (the pool's warm).
    private var answered: (@MainActor () -> Void)?

    /// - Parameter clock: The probe's timeout and the recheck wait run on it (tests pass a manual clock).
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        timer = DemandTimer(owner: "WebKitSetupGate.timeout", clock: clock)
        rechecks = DemandTimer(owner: "WebKitSetupGate.recheck", clock: clock)
    }

    /// Starts the request once (a slow gate asks again on its own, after its recheck wait); `answered`
    /// runs on the main actor when the setup answers in time.
    public func probe(answered: @escaping @MainActor () -> Void) {
        self.answered = answered
        guard state == .unknown else { return }
        ask()
    }

    /// A caller saw a web view hold the main thread: no spare until the setup is asked again.
    public func markSlow() { becameSlow() }

    private func ask() {
        guard !inFlight else { return }
        state = .probing
        inFlight = true
        let request = request
        // A wedged sandboxd never returns: not on a cooperative thread.
        Thread.detachNewThread {
            request()
            Task { @MainActor [weak self] in self?.returned() }
        }
        timer.schedule(after: Self.timeout) { @MainActor [weak self] in
            if self?.state == .probing { self?.becameSlow() }
        }
    }

    private func returned() {
        inFlight = false
        guard state == .probing else {
            // A late answer after a slow mark: asked again on the recheck schedule.
            if state == .slow, !rechecks.isScheduled { scheduleRecheck() }
            return
        }
        timer.cancel()
        state = .ready
        answered?()
    }

    private func becameSlow() {
        state = .slow
        scheduleRecheck()
    }

    private func scheduleRecheck() {
        let wait = min(Self.recheck * (1 << min(slowMarks, 8)), Self.longestRecheck)
        slowMarks += 1
        rechecks.schedule(after: wait) { @MainActor [weak self] in
            guard let self, state == .slow else { return }
            ask()
        }
    }

    /// Issues and drops one read extension for the temporary folder, as WebKit's first load does.
    @Sendable public nonisolated static func issueSandboxExtension() {
        typealias Issue = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_issue_file") else { return }
        free(unsafeBitCast(symbol, to: Issue.self)("com.apple.app-sandbox.read", NSTemporaryDirectory(), 0))
    }
}
