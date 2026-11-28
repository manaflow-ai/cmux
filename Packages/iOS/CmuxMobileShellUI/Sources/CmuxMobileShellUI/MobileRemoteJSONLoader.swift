#if os(iOS)
import Foundation

/// The shared loader for small remote JSON lists fetched from the cmux API
/// origin (What's New, Mac minimum versions): revalidating cache policy so
/// the server's ETag short-circuits unchanged payloads, a JSON Accept
/// header, a 10s timeout, and non-2xx responses surfaced as errors. One
/// definition so retries, auth headers, or timeout changes apply to every
/// consumer consistently.
let mobileRemoteJSONLoader: @Sendable (URL) async throws -> Data = { url in
    var request = URLRequest(
        url: url,
        cachePolicy: .reloadRevalidatingCacheData,
        timeoutInterval: 10
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse,
          (200...299).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
    }
    return data
}
#endif
