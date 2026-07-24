internal import Foundation
public import CmuxSubrouter

extension SubrouterQuotaAssessment {
    /// A localized one-line detail (which window saturated and when it
    /// resets), or `nil` when the account is not limited.
    public var detailText: String? {
        switch self {
        case .ok:
            return nil
        case .tempCooked(let window), .cooked(let window):
            let label = window.displayLabel
            if let reset = window.resetCountdownText {
                return String(
                    localized: "subrouter.quota.consumedWithReset",
                    defaultValue: "\(label) fully consumed, \(reset)"
                )
            }
            return String(
                localized: "subrouter.quota.consumed",
                defaultValue: "\(label) fully consumed"
            )
        }
    }
}
