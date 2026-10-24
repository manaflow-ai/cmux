public import Foundation

/// The team's prepaid cmux credits (`GET /v1/credits`, backend credits-routes.ts): what is left to
/// spend, and the top-up amounts the payment page sells.
public nonisolated struct CloudCreditsBalance: Sendable, Equatable {
    /// Credits left to spend, in USD (the balance less what running calls hold).
    public var availableUSD: Double
    /// The amounts, in USD, a top-up offers; empty when this deployment sells none.
    public var amountsUSD: [Int]

    /// - Parameters:
    ///   - availableUSD: credits left to spend, in USD.
    ///   - amountsUSD: the top-up amounts on offer, in USD.
    public init(availableUSD: Double, amountsUSD: [Int]) {
        self.availableUSD = availableUSD
        self.amountsUSD = amountsUSD
    }

    /// Reads the `{ok, value: {available_usd, topup: {amounts_usd} | null}}` envelope.
    /// - Throws: ``CloudCreditsError/badResponse`` when the answer is not that shape.
    public init(json data: Data) throws(CloudCreditsError) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["value"] as? [String: Any],
              let available = (value["available_usd"] as? NSNumber)?.doubleValue else { throw .badResponse }
        let amounts = ((value["topup"] as? [String: Any])?["amounts_usd"] as? [NSNumber])?.map(\.intValue) ?? []
        self.init(availableUSD: available, amountsUSD: amounts)
    }
}
