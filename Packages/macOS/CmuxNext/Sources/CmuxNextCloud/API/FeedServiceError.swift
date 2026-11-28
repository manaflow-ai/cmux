import CmuxEgress
public import Foundation

/// Why a call to the API Worker as the signed-in user (the App's `FeedService.call`) failed;
/// `HomeDirectory` (CmuxNextHomeEngine) throws and reads it too.
public enum FeedServiceError: Error, Sendable {
    /// No signed-in account.
    case signedOut
    /// The reply was not a JSON object.
    case badReply
    /// The owner (a Durable Object behind the Worker) refused: its error `code` and `message`.
    case owner(code: String, message: String)
}

extension URLSession {
    /// Requests that carry the account's bearer or install token: ephemeral, no URL cache, no cookies, so no
    /// answer (or the request headers stored with it) lands in `~/Library/Caches/<bundle id>/Cache.db`.
    public static let cloudNoStore: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return CmuxEgress.session(site: "CmuxNextCloud.cloudNoStore", configuration: configuration)
    }()
}
