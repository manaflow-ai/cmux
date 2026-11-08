/// One-shot result storage owned by the navigation ticket returned to a caller.
@MainActor
final class BrowserAutomationNavigationTransaction {
    private var terminalOutcome: BrowserAutomationNavigationOutcome?
    private var waiter: AsyncStream<BrowserAutomationNavigationOutcome>.Continuation?

    func takeTerminalOutcome() -> BrowserAutomationNavigationOutcome? {
        defer { terminalOutcome = nil }
        return terminalOutcome
    }

    func makeEventStream() -> AsyncStream<BrowserAutomationNavigationOutcome> {
        let (events, continuation) = AsyncStream.makeStream(
            of: BrowserAutomationNavigationOutcome.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        waiter?.finish()
        waiter = continuation
        return events
    }

    func finish(with outcome: BrowserAutomationNavigationOutcome) {
        terminalOutcome = outcome
        waiter?.yield(outcome)
        waiter?.finish()
        waiter = nil
    }

    func cancelWaiter() {
        waiter?.finish()
        waiter = nil
    }

    func discardTerminalOutcome() {
        terminalOutcome = nil
    }
}
