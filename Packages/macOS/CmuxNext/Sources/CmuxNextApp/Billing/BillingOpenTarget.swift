import Foundation

/// Where a checkout or billing page opened (`opened_in` of the result).
nonisolated enum BillingOpenTarget: String, Sendable, Equatable {
    case cmuxBrowser = "cmux"
    case defaultBrowser = "default"
    case nowhere = "none"
}
