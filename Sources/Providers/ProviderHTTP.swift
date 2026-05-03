import Foundation

// MARK: - Shared HTTP plumbing for provider fetchers
//
// Claude, Codex, and Statuspage.io fetchers all need the same shape: an
// ephemeral URLSession (no disk cookie/cache storage for credentials), a
// short timeout, a GET that expects `application/json`, a response-type
// check, an HTTP 200 gate, and JSON decoding. Centralizing it here keeps
// each concrete fetcher focused on its provider-specific parsing.

enum ProviderHTTPError: Error {
    case badResponse
    case http(Int)
    case decoding
    case network(Error)
}

enum ProviderHTTP {

    /// Returns a fresh ephemeral `URLSession` with the requested request /
    /// resource timeout (seconds). Ephemeral sessions don't persist cookies
    /// or URL cache to disk, which is important for credential-bearing
    /// requests — a crashed process mustn't leave a plaintext cookie in
    /// `~/Library/Caches`.
    static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// GETs `url` with optional `Cookie` / `Authorization` / `chatgpt-account-id`
    /// style headers (already sanitized by the caller) and returns the JSON
    /// top-level object. Header values pass through `sanitizeHeaderValue`,
    /// which strips control characters and cookie attribute separators so a
    /// malformed credential can't smuggle extra directives into the request.
    static func getJSONObject(
        url: URL,
        headers: [String: String] = [:],
        session: URLSession
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(sanitizeHeaderValue(value), forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession surfaces cooperative task cancellation as
            // `URLError.cancelled`; forward it as `CancellationError` so
            // callers can handle cancellation through one code path.
            throw CancellationError()
        } catch {
            // Defensive: if the surrounding Task was cancelled, treat any
            // resulting error as cancellation rather than a network failure.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw ProviderHTTPError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderHTTPError.badResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ProviderHTTPError.http(httpResponse.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderHTTPError.decoding
        }
        return json
    }

    /// Strips every byte that would change the semantics of an HTTP header:
    /// control characters (including `\r\n\t\0`) and cookie attribute
    /// separators (`;` and `,`). Upstream provider fetchers already validate
    /// credential shape, but this acts as a last-line defense so a malformed
    /// value can never inject extra directives into the wire request.
    static func sanitizeHeaderValue(_ value: String) -> String {
        var disallowed = CharacterSet.controlCharacters
        disallowed.insert(charactersIn: ";,")
        let scalars = value.unicodeScalars.filter { !disallowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
