package import CmuxNextCloud
package import CmuxNextCodeRouter
import Foundation

extension CodeRouterClient {
    /// The signed-in client for cmux.com's billing routes (`/api/billing/plan`, `/api/billing/checkout`): they are the
    /// website's, on ``CloudConfiguration/authWebOrigin``, not the Cloud API's (cmux issue 59902: `cmux billing status`
    /// asked `cloud-api.cmux.dev` and got 404, so the plan read, Checkout and Manage Billing all failed).
    @MainActor package static func billing(_ configuration: CloudConfiguration, account: any CodeRouterAccountSource,
                                           labeler: @escaping Labeler) -> CodeRouterClient {
        CodeRouterClient(baseURL: configuration.authWebOrigin, account: account, labeler: labeler)
    }
}

extension CodeRouterError {
    /// The `cmux billing` error code and message for this failure; cmux.com's own code
    /// (`team_admin_required`, `plan_unavailable`, …) passes through.
    package var billingFailure: (code: String, message: String) {
        switch self {
        case .notSignedIn: ("not_signed_in", BillingStrings.notSignedIn)
        case .scopeChanged: ("scope_changed", description)
        case .timedOut: ("timeout", description)
        case .http(let status, let code, _): (code ?? "http_\(status)", description)
        case .transport: ("unavailable", description)
        case .decoding: ("bad_response", BillingStrings.badResponse)
        }
    }
}
