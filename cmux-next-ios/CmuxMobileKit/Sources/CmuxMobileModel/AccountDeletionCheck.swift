import Foundation

/// What Delete Account learns before it asks (App Store Review Guideline
/// 5.1.1(v)): deleting a cmux account does not cancel an App Store
/// subscription, and Apple keeps charging until it is cancelled in the App
/// Store. The cmux web service answers `GET /api/account/deletion-check`
/// with `{ appStoreSubscriptionRenews, manageSubscriptionsUrl }`
/// (`docs/billing/ios-in-app-purchases.md`, "Account deletion").
public enum AccountDeletionCheck: Equatable, Sendable {
    /// An App Store subscription on the account will renew; `manageURL` is
    /// Apple's subscription management page.
    case appStoreSubscriptionRenews(manageURL: URL)
    /// Nothing renews through the App Store.
    case nothingToWarn

    /// Apple's subscription management page, the fallback when StoreKit
    /// cannot show its own sheet.
    public static let appleManageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    private struct Response: Decodable {
        let appStoreSubscriptionRenews: Bool
        let manageSubscriptionsUrl: String?
    }

    /// Decodes the service's answer. A management link that is not Apple's
    /// own page is replaced with it: the button only ever opens Apple.
    public static func decode(_ data: Data) throws -> AccountDeletionCheck {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.appStoreSubscriptionRenews else { return .nothingToWarn }
        if let url = response.manageSubscriptionsUrl.flatMap(URL.init(string:)),
           url.scheme == "https", url.host() == "apps.apple.com" {
            return .appStoreSubscriptionRenews(manageURL: url)
        }
        return .appStoreSubscriptionRenews(manageURL: appleManageSubscriptionsURL)
    }
}

/// The alert Delete Account shows.
public enum AccountDeletionPrompt: Equatable, Sendable {
    /// The App Store warning: Manage Subscription, Delete Account, Cancel.
    case appStoreSubscriptionWarning(manageURL: URL)
    /// The plain confirmation: Delete Account, Cancel.
    case confirmation

    /// The prompt for a check's answer. `nil` is a check that could not be
    /// read (offline, a server error): the plain confirmation, because the
    /// check never stands between a user and deleting their account.
    public init(check: AccountDeletionCheck?) {
        switch check {
        case .appStoreSubscriptionRenews(let manageURL): self = .appStoreSubscriptionWarning(manageURL: manageURL)
        case .nothingToWarn, nil: self = .confirmation
        }
    }
}

/// A failed `GET /api/account/deletion-check`.
public enum AccountDeletionCheckError: Error, Equatable, Sendable {
    case invalidBaseURL
    case unauthorized
    case status(Int)
    case invalidResponse
}

/// `GET <origin>/api/account/deletion-check` with the account's Stack tokens,
/// the same native auth headers `DELETE /api/account` sends.
public struct AccountDeletionCheckClient: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let origin: URL
    private let timeout: TimeInterval
    private let load: Loader

    /// - Parameters:
    ///   - origin: The cmux web origin account deletion goes to.
    ///   - timeout: Short: the user is waiting on the Delete Account button.
    ///   - load: The transport (tests inject one).
    public init(origin: URL, timeout: TimeInterval = 10, load: @escaping Loader = { try await URLSession.shared.data(for: $0) }) {
        self.origin = origin
        self.timeout = timeout
        self.load = load
    }

    public func check(accessToken: String, refreshToken: String) async throws -> AccountDeletionCheck {
        let url = origin.appending(path: "api/account/deletion-check")
        guard url.scheme == "https" || url.scheme == "http" else { throw AccountDeletionCheckError.invalidBaseURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse else { throw AccountDeletionCheckError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            do { return try AccountDeletionCheck.decode(data) } catch { throw AccountDeletionCheckError.invalidResponse }
        case 401: throw AccountDeletionCheckError.unauthorized
        default: throw AccountDeletionCheckError.status(http.statusCode)
        }
    }
}

#if DEBUG
public extension AccountDeletionCheck {
    /// DEBUG screenshot rig, like `CMUX_MOBILE_BILLING_DEMO`:
    /// `CMUX_MOBILE_ACCOUNT_DELETION_DEMO=app-store-renewing` answers that an
    /// App Store subscription renews, `none` that nothing does, and
    /// `unavailable` that the check failed (`.some(nil)`). Unset: `nil`, ask
    /// the service.
    static func demo(environment: [String: String]) -> AccountDeletionCheck?? {
        switch environment["CMUX_MOBILE_ACCOUNT_DELETION_DEMO"] {
        case "app-store-renewing": .some(.appStoreSubscriptionRenews(manageURL: appleManageSubscriptionsURL))
        case "none": .some(.nothingToWarn)
        case "unavailable": .some(nil)
        default: nil
        }
    }
}
#endif
