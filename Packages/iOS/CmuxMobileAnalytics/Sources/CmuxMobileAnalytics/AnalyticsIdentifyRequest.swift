import CMUXMobileCore

struct AnalyticsIdentifyRequest: Sendable {
    let userID: String?
    let alias: String?
    let properties: [String: AnalyticsValue]
}
