/// The phase an install policy observes, independent of the callbacks and appcast item in the UI state.
package enum UpdateLifecyclePhase: String, CaseIterable, Sendable {
    case idle
    case permissionRequest
    case preparingCheck
    case checking
    case updateAvailable
    case notFound
    case error
    case startingDownload
    case downloading
    case extracting
    case installing
}
