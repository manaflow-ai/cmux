public import CMUXAuthCore
import CryptoKit
public import Foundation
import Security

/// Redeems the one-time code a hosted sign-in hands back in
/// `<scheme>://auth-callback?code=…` for the session tokens. The code is useless
/// without the attempt's PKCE verifier, which never leaves the app.
public protocol AuthCallbackCodeRedeeming: Sendable {
    /// The sign-in origin (`scheme://host[:port]`) this redeemer talks to.
    var signInOrigin: String { get }
    /// Whether the sign-in origin hands sign-ins over with a one-time code
    /// (it lists S256). Asked before the browser opens.
    func codeExchangeCapability() async -> CodeExchangeCapability
    /// Exchanges `code` and `verifier` for the session tokens.
    func redeem(code: String, verifier: String) async throws -> AuthCallbackPayload
}

/// What a sign-in origin said about the one-time code hand-off.
public enum CodeExchangeCapability: Sendable, Equatable {
    /// The origin lists S256: hand off with a code.
    case supported
    /// The origin definitively has no code route (404, or a valid answer without S256).
    case unsupported
    /// No definitive answer (unreachable, timeout, 5xx, redirect, unreadable body).
    case unknown
}

/// Remembers across launches each sign-in origin that has offered the code
/// hand-off, in the app's auth key-value store, so a later launch never
/// probes its way back to the token hand-off for that origin.
///
/// `@unchecked Sendable`: the only state is the injected store and an
/// immutable key; the production backing (`UserDefaults`) is thread-safe.
public final class HostBrowserCodeExchangeMemory: @unchecked Sendable {
    private let keyValueStore: any CMUXAuthKeyValueStore
    private let key: String

    /// - Parameters:
    ///   - keyValueStore: The app's auth key-value store.
    ///   - key: The key the remembered origins persist under.
    public init(keyValueStore: any CMUXAuthKeyValueStore, key: String) {
        self.keyValueStore = keyValueStore
        self.key = key
    }

    private var origins: [String] {
        keyValueStore.string(forKey: key)?.split(separator: "\n").map(String.init) ?? []
    }

    /// Whether `origin` has offered the code hand-off before.
    public func supportsCodeExchange(origin: String) -> Bool {
        origins.contains(origin)
    }

    /// Records that `origin` offered the code hand-off. Never forgotten.
    public func recordSupported(origin: String) {
        var known = origins
        guard !origin.isEmpty, !known.contains(origin) else { return }
        known.append(origin)
        keyValueStore.set(known.joined(separator: "\n"), forKey: key)
    }
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

    private struct Capability: Decodable {
        let pkce: [String]
    }

    /// One request may take this long; the code itself lives 60 seconds.
    static let requestTimeout: TimeInterval = 10
    /// The capability check runs before the browser opens, so it is kept short.
    static let capabilityTimeout: TimeInterval = 5

    public var signInOrigin: String { Self.origin(of: endpoint) }

    /// `scheme://host[:port]` of `url`, lowercased.
    static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// Whether `url` is HTTPS, or plain HTTP to this machine (local development).
    static func isSecureOrLoopback(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        default: false
        }
    }

    /// `GET /api/native/token`. Only two answers from the origin itself are
    /// definitive: `200` with `{"pkce":[...]}` (supported when it lists S256)
    /// and `404` (a deployment without the route). A transport error, a
    /// timeout, any other status, a redirect or a body that does not parse is
    /// ``CodeExchangeCapability/unknown``.
    public func codeExchangeCapability() async -> CodeExchangeCapability {
        guard Self.isSecureOrLoopback(endpoint) else { return .unknown }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.capabilityTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await transport(request),
              let http = response as? HTTPURLResponse else {
            return .unknown
        }
        // A followed redirect answered from somewhere else: not the origin's answer.
        if let answeredBy = http.url, answeredBy.absoluteString != endpoint.absoluteString { return .unknown }
        switch http.statusCode {
        case 404:
            return .unsupported
        case 200:
            guard let capability = try? JSONDecoder().decode(Capability.self, from: data) else { return .unknown }
            return capability.pkce.contains("S256") ? .supported : .unsupported
        default:
            return .unknown
        }
    }

    public func redeem(code: String, verifier: String) async throws -> AuthCallbackPayload {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
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
        } catch let error as URLError where error.code == .cancelled {
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

/// How one callback state hands the sign-in back, fixed before its URL is
/// opened: with a one-time code for this PKCE pair, or (for a sign-in origin
/// without the code route) with the token pair.
enum HostBrowserHandoffMode: Sendable, Equatable {
    case pkce(HostBrowserPKCE)
    case legacy
}

/// The hand-off mode of the app's live and recently issued callback states.
/// Bounded: the oldest is dropped past ``capacity``, and a stateful callback
/// whose mode is gone is refused. A mode is taken (removed) by the callback
/// that uses it.
@MainActor
struct HostBrowserHandoffModes {
    static let capacity = 8
    private var entries: [(state: String, mode: HostBrowserHandoffMode)] = []

    /// The mode chosen for `state`, if any.
    func mode(for state: String) -> HostBrowserHandoffMode? {
        entries.first { HostBrowserIssuedCallbackStates.constantTimeEquals($0.state, state) }?.mode
    }

    /// Records `mode` for `state` unless it already has one; a state's mode never changes.
    mutating func choose(_ mode: HostBrowserHandoffMode, for state: String) {
        guard self.mode(for: state) == nil else { return }
        entries.append((state, mode))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// Removes and returns the mode for `state`.
    mutating func take(_ state: String) -> HostBrowserHandoffMode? {
        guard let index = entries.firstIndex(where: { HostBrowserIssuedCallbackStates.constantTimeEquals($0.state, state) }) else {
            return nil
        }
        return entries.remove(at: index).mode
    }

    /// Drops every mode except `kept`'s.
    mutating func removeAll(keeping kept: String?) {
        entries.removeAll { !HostBrowserIssuedCallbackStates.constantTimeEquals($0.state, kept) }
    }
}
