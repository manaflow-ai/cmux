/// The observable result of asking the Computer Use helper to raise a native permission request.
enum ComputerUsePermissionRequestOutcome: Sendable {
    case accepted
    case rejected
    case unknown
}
