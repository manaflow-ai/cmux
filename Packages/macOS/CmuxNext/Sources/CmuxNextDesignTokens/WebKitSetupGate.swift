public import CmuxNextWakeups
package import Darwin
public import Foundation

/// Whether WebKit's setup answers on this host, asked off the main thread before a web view is
/// made where nobody waits for it (the New Tab spare). A WKWebView's first load issues sandbox
/// extensions and registers the user's fonts on the main thread; with a wedged sandboxd that held
/// launch for more than 10 s (cua-2, 2026-10-14). Unknown until ``probe()``; ready when the
/// sandbox broker answered; slow when it did not answer within ``timeout``, or a caller saw a web
/// view hold the main thread (``markSlow()``). A slow setup stays slow for the run.
///
/// Nobody sees the probe: its answer and its timeout reach main as `background` tasks on the app's
/// scheduler (Chromium posts such startup work `BEST_EFFORT`, base/task/task_traits.h), so the launch
/// holds both until it reveals the first window, in order: an answer posted before the timeout's wake
/// runs first.
public final class WebKitSetupGate {
    public enum State: Sendable { case unknown, probing, ready, slow }
    public private(set) var state = State.unknown
    public static let timeout: Duration = .seconds(2)
    /// The blocking request, run on a thread of its own; tests put a wedged one in its place.
    public var request: @Sendable () -> Void = WebKitSetupGate.issueSandboxExtension
    private let timer: MainDeadline
    private let mainWork: MainWorkScheduler
    private let answerOwner: MainTaskOwner

    /// - Parameter deadlines: The app's deadline scheduler: the timeout is a deadline on it, the answer a
    ///   task on its main-thread scheduler.
    public init(deadlines: MainDeadlineScheduler) {
        timer = MainDeadline(owner: "WebKitSetupGate.timeout", workClass: .background, scheduler: deadlines)
        mainWork = deadlines.work
        answerOwner = deadlines.work.board.owner("WebKitSetupGate.answer")
    }

    /// Starts the request once; `answered` runs on the main actor if it answers in time.
    public func probe(answered: @escaping @MainActor () -> Void) {
        guard state == .unknown else { return }
        state = .probing
        let request = request, mainWork = mainWork, owner = answerOwner
        let answer: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, state == .probing else { return }
            state = .ready
            timer.cancel()
            answered()
        }
        // A wedged sandboxd never returns: not on a cooperative thread. Nobody waits for the answer
        // (the gate only decides whether to make the spare), so it runs at utility.
        let thread = Thread {
            request()
            mainWork.postFromAnyThread(.background, owner: owner, answer)
        }
        thread.name = "cmux-next webkit setup probe"
        thread.qualityOfService = .utility
        thread.start()
        timer.schedule(after: Self.timeout) { [weak self] in
            if self?.state == .probing { self?.state = .slow }
        }
    }

    public func markSlow() { state = .slow }

    /// Issues and drops one read extension for the temporary folder, as WebKit's first load does.
    @Sendable public nonisolated static func issueSandboxExtension() {
        typealias Issue = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_issue_file") else { return }
        free(unsafeBitCast(symbol, to: Issue.self)("com.apple.app-sandbox.read", NSTemporaryDirectory(), 0))
    }
}
