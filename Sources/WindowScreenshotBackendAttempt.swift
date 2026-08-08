#if DEBUG
/// The bounded outcome of one independently admitted screenshot backend.
enum WindowScreenshotBackendAttempt<Value: Sendable>: Sendable {
    case captured(Value)
    case unavailable
    case busy
    case timedOut

    var capturedValue: Value? {
        guard case .captured(let value) = self else { return nil }
        return value
    }

    var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }

    var didTimeOut: Bool {
        if case .timedOut = self { return true }
        return false
    }
}
#endif
