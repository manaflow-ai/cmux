// Safety: every associated request documents its transfer invariant, and the
// coordinator removes each operation from its actor queue exactly once.
enum TerminalSurfaceRuntimeNativeOperation: @unchecked Sendable {
    case creation(TerminalSurfaceRuntimeCreationRequest)
    case screenTail(TerminalSurfaceRuntimeQueuedScreenTail)
    case teardown(TerminalSurfaceRuntimeQueuedTeardown)
}
