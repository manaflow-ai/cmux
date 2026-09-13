import Foundation

enum CloudTuiCreationResolutionState: String, Equatable, Sendable {
    case pending
    case created
    case notApplied = "not_applied"
    case indeterminate
}
