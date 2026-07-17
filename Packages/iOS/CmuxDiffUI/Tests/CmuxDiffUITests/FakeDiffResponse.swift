import CmuxMobileShell

enum FakeDiffResponse<Value: Sendable>: Sendable {
    case success(Value)
    case serviceFailure(MobileDiffsServiceError)
    case transportFailure
}
