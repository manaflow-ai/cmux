/// Internal result from racing browser automation liveness callbacks against their deadline.
enum BrowserAutomationProbeSignal: Sendable {
    case responsive
    case timedOut
    case cancelled
}
