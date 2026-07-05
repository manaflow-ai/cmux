import AppKit
import CmuxInbox
import CryptoKit
import Foundation
import Network
import Security

/// Runs the real Google sign-in for Gmail: loopback redirect (RFC 8252) with
/// PKCE, browser consent, code exchange, and vault storage of a refreshable
/// credential. The OAuth client id comes from cmux.json
/// (`integrations.gmail.client_id`, optional `client_secret` for Web-type
/// clients); Google Desktop-type clients need no secret.
@MainActor
final class GmailOAuthCoordinator {
    struct ClientConfiguration {
        let clientID: String
        let clientSecret: String?

        /// Reads the OAuth client from ~/.config/cmux/cmux.json.
        static func fromCmuxConfig() -> ClientConfiguration? {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/cmux/cmux.json")
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let integrations = root["integrations"] as? [String: Any],
                  let gmail = integrations["gmail"] as? [String: Any],
                  let clientID = gmail["client_id"] as? String,
                  !clientID.isEmpty else { return nil }
            return ClientConfiguration(clientID: clientID, clientSecret: gmail["client_secret"] as? String)
        }
    }

    enum OAuthError: Error {
        case listenerFailed
        case browserRejected
        case stateMismatch
        case cancelled
        case entropyUnavailable
    }

    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []

    /// Runs the full sign-in and returns the credential JSON for the vault.
    func signIn(configuration: ClientConfiguration) async throws -> String {
        defer { stop() }
        let verifier = try Self.randomURLSafeString(length: 64)
        let state = try Self.randomURLSafeString(length: 32)
        let challenge = GmailOAuthCredential.codeChallenge(for: verifier)

        // Loopback interface only (RFC 8252 section 7.3): binding to all
        // interfaces would let LAN peers probe the port and abort the flow
        // with a bad-state request while sign-in is pending.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            var finished = false
            let finish: @Sendable (Result<String, any Error>) -> Void = { result in
                Task { @MainActor in
                    guard !finished else { return }
                    finished = true
                    continuation.resume(with: result)
                }
            }
            // Abandoned consent (browser tab closed, user walks away) must not
            // leak the listener and the awaiting task until app exit.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.signInTimeout * 1_000_000_000))
                finish(.failure(OAuthError.cancelled))
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.activeConnections.append(connection) }
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    let result = Self.parseCallback(requestLine: request, expectedState: state)
                    let body: String
                    switch result {
                    case .success:
                        body = String(localized: "inbox.gmail.oauth.successPage", defaultValue: "Gmail is connected. You can close this tab and return to cmux.")
                    case .failure:
                        body = String(localized: "inbox.gmail.oauth.failurePage", defaultValue: "Gmail sign-in failed. Return to cmux and try again.")
                    }
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<html><body style=\"font-family:-apple-system;padding:40px\"><h3>\(body)</h3></body></html>"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    if case .success(let code) = result {
                        finish(.success(code))
                    } else if case .failure(let error) = result, case OAuthError.stateMismatch = error {
                        finish(.failure(error))
                    }
                    // Other requests (favicon, wrong path) keep the listener alive.
                }
            }
            // The port is published exactly when the listener reaches .ready;
            // launching the browser from there avoids polling.
            listener.stateUpdateHandler = { [weak self] listenerState in
                switch listenerState {
                case .ready:
                    Task { @MainActor in
                        guard let self, let port = listener.port?.rawValue, port > 0 else {
                            finish(.failure(OAuthError.listenerFailed))
                            return
                        }
                        let redirect = "http://127.0.0.1:\(port)/callback"
                        self.pendingRedirectURI = redirect
                        let url = GmailOAuthCredential.authorizationURL(
                            clientID: configuration.clientID,
                            redirectURI: redirect,
                            state: state,
                            codeChallenge: challenge
                        )
                        NSWorkspace.shared.open(url)
                    }
                case .failed, .cancelled:
                    finish(.failure(OAuthError.listenerFailed))
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }

        guard let redirectURI = pendingRedirectURI else { throw OAuthError.listenerFailed }
        let exchange = GmailOAuthCredential.tokenExchangeRequest(
            clientID: configuration.clientID,
            clientSecret: configuration.clientSecret,
            code: code,
            redirectURI: redirectURI,
            codeVerifier: verifier
        )
        let (data, _) = try await URLSession.shared.data(for: exchange)
        let credential = try GmailOAuthCredential.parseTokenResponse(
            data: data,
            clientID: configuration.clientID,
            clientSecret: configuration.clientSecret,
            now: Date.now
        )
        return String(data: try credential.encoded(), encoding: .utf8) ?? ""
    }

    /// Upper bound for the whole consent round trip before the flow is
    /// abandoned and the loopback listener torn down.
    private static let signInTimeout: TimeInterval = 300

    private var pendingRedirectURI: String?

    private func stop() {
        listener?.cancel()
        listener = nil
        activeConnections.forEach { $0.cancel() }
        activeConnections = []
    }

    /// Parses "GET /callback?code=...&state=... HTTP/1.1" without trusting anything else.
    nonisolated static func parseCallback(requestLine: String, expectedState: String) -> Result<String, any Error> {
        guard let firstLine = requestLine.components(separatedBy: "\r\n").first,
              firstLine.hasPrefix("GET "),
              let target = firstLine.components(separatedBy: " ").dropFirst().first,
              let components = URLComponents(string: target),
              components.path == "/callback" else {
            return .failure(OAuthError.browserRejected)
        }
        // Duplicate keys must fail cleanly, not trap: any local request (or a
        // page redirecting the browser to the loopback port) could send
        // /callback?state=x&state=y during sign-in.
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil else { return .failure(OAuthError.browserRejected) }
            query[item.name] = item.value ?? ""
        }
        guard query["state"] == expectedState else { return .failure(OAuthError.stateMismatch) }
        guard let code = query["code"], !code.isEmpty else { return .failure(OAuthError.browserRejected) }
        return .success(code)
    }

    /// Fails closed: a zeroed buffer would make the PKCE verifier and state
    /// predictable, so an entropy failure aborts the sign-in.
    nonisolated static func randomURLSafeString(length: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, length, &bytes) == errSecSuccess else {
            throw OAuthError.entropyUnavailable
        }
        return Data(bytes).base64URLEncoded().prefix(length).description
    }
}
