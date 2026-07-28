enum ApplicationCaptureState: Equatable {
    case starting
    case streaming
    case suspended
    case permissionRequired
    case windowUnavailable
    case failed
}
