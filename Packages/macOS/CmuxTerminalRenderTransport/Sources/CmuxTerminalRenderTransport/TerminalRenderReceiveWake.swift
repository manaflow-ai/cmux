/// Internal wake reason for one cancellable Mach receive deadline.
enum TerminalRenderReceiveWake: Sendable {
    case ready
    case timedOut
    case stopped
    case cancelled
}
