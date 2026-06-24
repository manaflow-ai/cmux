#if os(iOS)
import Foundation

actor TerminalTextCaptureRaceState {
    private var continuation: CheckedContinuation<(timedOut: Bool, text: String?), Never>?
    private var completedOutcome: (timedOut: Bool, text: String?)?
    private var waiter: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func install(continuation: CheckedContinuation<(timedOut: Bool, text: String?), Never>) {
        if let completedOutcome {
            continuation.resume(returning: completedOutcome)
        } else {
            self.continuation = continuation
        }
    }

    func setWaiter(_ waiter: Task<Void, Never>) {
        if completedOutcome != nil {
            waiter.cancel()
        } else {
            self.waiter = waiter
        }
    }

    func setTimer(_ timer: Task<Void, Never>) {
        if completedOutcome != nil {
            timer.cancel()
        } else {
            self.timer = timer
        }
    }

    func cancel() {
        finish(timedOut: true, text: nil)
    }

    func finish(timedOut: Bool, text: String?) {
        guard completedOutcome == nil else { return }
        let outcome = (timedOut: timedOut, text: text)
        completedOutcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        let waiter = self.waiter
        self.waiter = nil
        let timer = self.timer
        self.timer = nil

        waiter?.cancel()
        timer?.cancel()
        continuation?.resume(returning: outcome)
    }
}
#endif
