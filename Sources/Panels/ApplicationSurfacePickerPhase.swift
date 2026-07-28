enum ApplicationSurfacePickerPhase: Equatable {
    case idle
    case loading
    case ready
    case permissionRequired
    case helperUnavailable
    case failed(String)
}
