public import Foundation

/// HTTP credentials REPL sessions gave in the URLs they navigated a tab to
/// (`http://user:password@host/`), kept per session and `host:port`.
///
/// A driven tab has nobody to answer an HTTP authentication prompt, so the
/// tab answers a challenge from these. A session's credentials answer only
/// its own requests: those its own navigation or input makes (the acting
/// session, ``BrowserReplTabOwnership/inputSessionID``), and every request of
/// a tab it created. Another session driving the same tab never signs in
/// with them, and they end with the session. The answer's credential has no
/// persistence, so WebKit does not keep it for the data store, whose other
/// tabs (the user's, other sessions') would then send it.
public struct BrowserReplHTTPCredentials {
    private var bySession: [String: [String: URLCredential]] = [:]

    public init() {}

    /// Remembers the user name and password in `url`, if it has a user name,
    /// as `sessionID`'s for the URL's host and port.
    public mutating func remember(_ url: URL, sessionID: String) {
        guard let user = url.user, !user.isEmpty, let host = url.host else { return }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        bySession[sessionID, default: [:]][Self.key(host: host, port: port)] = URLCredential(
            user: user.removingPercentEncoding ?? user,
            password: (url.password ?? "").removingPercentEncoding ?? url.password ?? "",
            persistence: .none
        )
    }

    /// The credential that answers a challenge from `host:port`: the acting
    /// session's own, else the tab's live creator's. `nil` when neither gave
    /// one, also when another session did.
    /// - Parameters:
    ///   - actingSession: The one session whose input or navigation the
    ///     page is handling, if any.
    ///   - creator: The attached session that created the tab, if any.
    public func credential(host: String, port: Int, actingSession: String?, creator: String?) -> URLCredential? {
        let key = Self.key(host: host, port: port)
        for sessionID in [actingSession, creator].compactMap({ $0 }) {
            if let credential = bySession[sessionID]?[key] { return credential }
        }
        return nil
    }

    /// Forgets what `sessionID` gave, when it leaves the tab.
    public mutating func sessionLeft(_ sessionID: String) {
        bySession.removeValue(forKey: sessionID)
    }

    private static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }
}
