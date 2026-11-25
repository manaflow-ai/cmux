package import CmuxNextCodeRouter
package import CmuxNextPages
package import CmuxNextSettings
package import Foundation

/// The Cloud page's `cmux.cloud.billing.status`: `{payment_past_due}`, whether the signed-in account's
/// latest renewal failed. It is cmux.com's `paymentPastDue` from `GET /api/billing/plan`, the read
/// `cmux billing status` makes. The page reads it when it opens and when it is shown again (never on a
/// timer) and shows its notice beside Manage Billing only on a true answer. Signed out, a failed call
/// or a reply that does not say all answer false.
@MainActor
package final class BillingStatusPageProvider: PageProvider {
    /// The one op this provider serves (a longer prefix than `cmux.cloud.`, so the router picks it).
    package static let op = "cmux.cloud.billing.status"
    private let client: @MainActor () -> CodeRouterClient?

    /// - Parameter client: The signed-in cmux.com client; nil while signed out.
    package init(client: @escaping @MainActor () -> CodeRouterClient?) {
        self.client = client
    }

    package func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        guard let client = client(), let data = try? await client.request("GET", "/api/billing/plan") else {
            return ["payment_past_due": .bool(false)]
        }
        return ["payment_past_due": .bool(Self.paymentPastDue(planReply: data))]
    }

    /// `paymentPastDue` of a `GET /api/billing/plan` reply: true only for a JSON `true`. A missing
    /// field (an older server), another type or a body that is not JSON reads as false.
    package nonisolated static func paymentPastDue(planReply data: Data) -> Bool {
        struct Reply: Decodable { let paymentPastDue: Bool? }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.paymentPastDue == true
    }
}
