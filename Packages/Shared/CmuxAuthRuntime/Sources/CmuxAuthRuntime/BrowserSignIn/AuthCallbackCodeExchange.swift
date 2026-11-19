import CryptoKit
public import Foundation
import Security

/// Redeems the one-time code a hosted sign-in hands back in
/// `<scheme>://auth-callback?code=…` for the session tokens. The code is useless
/// without the attempt's PKCE verifier, which never leaves the app.
public protocol AuthCallbackCodeRedeeming: Sendable {
    /// Exchanges `code` and `verifier` for the session tokens.
    func redeem(code: String, verifier: String) async throws -> AuthCallbackPayload
}

/// Redeems sign-in codes at the hosted sign-in origin's `POST /api/native/token`,
/// over HTTPS, with the tokens in the JSON response body only.
public struct NativeSignInCodeRedeemer: AuthCallbackCodeRedeeming {
    /// Sends one request and returns its body and response.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let endpoint: URL
    private let scheme: String
    private let transport: Transport

    /// Creates a redeemer for the origin the app signs in on.
    /// - Parameters:
    ///   - authWebOrigin: The origin of the hosted sign-in pages.
    ///   - scheme: This build's callback scheme; the code is bound to it.
    ///   - transport: The network call, `URLSession.shared` by default.
    public init(
        authWebOrigin: URL,
        scheme: String,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        endpoint = authWebOrigin.appendingPathComponent("api/native/token")
        self.scheme = scheme
        self.transport = transport
    }

    private struct Body: Encodable {
        let code: String
        let codeVerifier: String
        let scheme: String

        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
            case scheme
        }
    }

    private struct Tokens: Decodable {
        let refreshToken: String
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
            case accessToken = "access_token"
        }
    }

    public func redeem(code: String, verifier: String) async throws -> AuthCallbackPayload {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Body(code: code, codeVerifier: verifier, scheme: scheme))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw AuthError.cancelled
        } catch {
            throw AuthError.networkError
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            break
        case 400:
            throw AuthError.invalidCallback
        case 429:
            throw AuthError.rateLimited
        default:
            throw AuthError.serverError(status, "code_redeem_failed")
        }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data),
              !tokens.refreshToken.isEmpty, !tokens.accessToken.isEmpty else {
            throw AuthError.serverError(status, "code_redeem_malformed")
        }
        return AuthCallbackPayload(refreshToken: tokens.refreshToken, accessToken: tokens.accessToken)
    }
}

/// One attempt's PKCE secret (RFC 7636, S256).
struct HostBrowserPKCE: Sendable, Equatable {
    /// 32 random bytes, base64url: 43 characters.
    let verifier: String

    /// `BASE64URL(SHA256(verifier))`.
    var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A fresh verifier from the system CSPRNG; nil only if it fails.
    static func make() -> HostBrowserPKCE? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return HostBrowserPKCE(verifier: base64URL(Data(bytes)))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// PKCE verifiers for the app's live and recently issued callback states.
/// Bounded: the oldest is dropped past ``capacity``. A verifier is taken
/// (removed) by the callback that redeems its code.
@MainActor
struct HostBrowserCodeVerifiers {
    static let capacity = 8
    private var entries: [(state: String, pkce: HostBrowserPKCE)] = []

    /// The PKCE pair for `state`, made on first use.
    mutating func pkce(for state: String) -> HostBrowserPKCE? {
        if let entry = entries.first(where: { HostBrowserIssuedCallbackStates.constantTimeEquals($0.state, state) }) {
            return entry.pkce
        }
        guard let pkce = HostBrowserPKCE.make() else { return nil }
        entries.append((state, pkce))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return pkce
    }

    /// Removes and returns the verifier for `state`.
    mutating func take(_ state: String) -> String? {
        guard let index = entries.firstIndex(where: { HostBrowserIssuedCallbackStates.constantTimeEquals($0.state, state) }) else {
            return nil
        }
        return entries.remove(at: index).pkce.verifier
    }

    /// Drops every verifier except `kept`'s.
    mutating func removeAll(keeping kept: String?) {
        entries.removeAll { !HostBrowserIssuedCallbackStates.constantTimeEquals($0.state, kept) }
    }
}
