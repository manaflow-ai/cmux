import CmuxNextCompat
import Foundation

/// Reads an rp id's related origins list, `https://<rp id>/.well-known/webauthn` (WebAuthn level 3,
/// "Related origin requests"). cmux fetches it itself and never takes the Chromium Host's answer
/// (plans/cmux-next/passkeys.md 3.9.3, rule 2).
protocol ChromiumRelatedOriginFetching: Sendable {
    /// The document's bytes, nil when there is none or it could not be read.
    func wellKnown(for rpID: String) async -> Data?
}

/// Whether a related origins document lists an origin, by Chromium's rules
/// (content/browser/webauth/webauth_request_security_checker.cc, `RemoteValidation::ValidateWellKnownJSON`):
/// `{"origins": [...]}`, origins counted by the first label of their registrable domain, and once 5 labels
/// were seen, an origin with a new label is skipped.
nonisolated struct ChromiumRelatedOrigins: Sendable {
    /// Chromium's `kMaxLabels`.
    static let maxLabels = 5

    let publicSuffixes: PublicSuffixList

    func lists(_ origin: String, in document: Data) -> Bool {
        guard let object = (try? JSONSerialization.blockingJSONObject(with: document)) as? [String: Any],
              let origins = object["origins"] as? [Any] else { return false }
        var labels: Set<String> = []
        for case let text as String in origins {
            guard let url = URL(string: text), let listed = ChromiumPasskeyPolicy.origin(of: url),
                  let host = url.host(percentEncoded: false), let domain = publicSuffixes.registrableDomain(of: host) else { continue }
            let label = String(domain.prefix { $0 != "." })
            if labels.count >= Self.maxLabels, !labels.contains(label) { continue }
            if listed == origin { return true }
            labels.insert(label)
        }
        return false
    }
}

/// The fetch Chromium makes for the list: no cookies or credentials, no redirects, JSON only, a bounded body.
nonisolated struct ChromiumRelatedOriginFetcher: ChromiumRelatedOriginFetching {
    /// Larger documents are refused.
    static let maxBytes = 256 * 1024

    /// Refuses every redirect, as Chromium's fetch of the list does.
    private nonisolated final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    func wellKnown(for rpID: String) async -> Data? {
        guard let url = URL(string: "https://\(rpID)/.well-known/webauthn") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request, delegate: NoRedirects()),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true,
              data.count <= Self.maxBytes else { return nil }
        return data
    }
}
