@preconcurrency import Foundation

struct ChromiumCDPEndpointDiscovery: Sendable {
    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func versionURL(port: Int) -> URL? {
        guard ChromiumRemoteDebuggingPort(rawValue: port)?.isExternallyAttachable == true else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/json/version")
    }

    func listURL(port: Int) -> URL? {
        guard ChromiumRemoteDebuggingPort(rawValue: port)?.isExternallyAttachable == true else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/json/list")
    }

    func browserWebSocketURL(port: Int) async throws -> URL {
        guard let url = versionURL(port: port) else { throw CDPError.invalidEndpoint }
        let (data, response) = try await session.data(from: url)
        try Self.validate(response, requestedURL: url, port: port)
        let payload = try JSONDecoder().decode(VersionPayload.self, from: data)
        guard let websocket = payload.webSocketDebuggerURL else { throw CDPError.malformedMessage }
        return try Self.validateWebSocket(websocket, port: port, kind: .browser)
    }

    /// Returns a page target websocket suitable for page-scoped CDP commands.
    ///
    /// Chromium exposes two websocket families: the browser websocket returned
    /// by `/json/version`, and one websocket per page returned by `/json/list`.
    /// Page domains (`Page`, `Runtime`, `Input`, and friends) must use the
    /// latter unless every command is wrapped in a Target session. Keeping the
    /// distinction here gives the session a single, testable discovery seam.
    func pageWebSocketURL(port: Int) async throws -> URL {
        try await pageTarget(port: port).webSocketDebuggerURL
            .unwrap(or: CDPError.protocolError(ChromiumBrowserDiagnostic.noPageWebSocket.message))
    }

    func pageTarget(port: Int) async throws -> ChromiumDiscoveredTarget {
        guard let url = listURL(port: port) else { throw CDPError.invalidEndpoint }
        let (data, response) = try await session.data(from: url)
        try Self.validate(response, requestedURL: url, port: port)
        let payload = try JSONDecoder().decode([TargetPayload].self, from: data)
        guard let target = payload.first(where: { $0.type == "page" && $0.webSocketDebuggerURL != nil }) else {
            throw CDPError.protocolError(ChromiumBrowserDiagnostic.noPageTarget.message)
        }
        let websocket = try target.webSocketDebuggerURL
            .flatMap(URL.init(string:))
            .map { try Self.validateWebSocket($0, port: port, kind: .page) }
            .unwrap(or: CDPError.malformedMessage)
        return ChromiumDiscoveredTarget(
            id: target.id,
            type: target.type,
            url: URL(string: target.url),
            webSocketDebuggerURL: websocket
        )
    }

    // Internal behavioral seams let the package test the same URL/port policy
    // used by live discovery without opening a real listener.
    static func validateForTesting(
        _ response: URLResponse,
        requestedURL: URL,
        port: Int
    ) throws {
        try validate(response, requestedURL: requestedURL, port: port)
    }

    static func validateWebSocketForTesting(
        _ url: URL,
        port: Int,
        kind: ChromiumCDPWebSocketKind
    ) throws {
        _ = try validateWebSocket(url, port: port, kind: kind)
    }

    private static func validate(
        _ response: URLResponse,
        requestedURL: URL,
        port: Int
    ) throws {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let finalURL = response.url,
              isLoopbackHTTPURL(finalURL, path: requestedURL.path, port: port) else {
            throw CDPError.disconnected(ChromiumBrowserDiagnostic.endpointUnavailable.message)
        }
    }

    private static func validateWebSocket(
        _ url: URL,
        port: Int,
        kind: ChromiumCDPWebSocketKind
    ) throws -> URL {
        guard url.scheme?.lowercased() == "ws",
              isLoopbackHost(url.host),
              url.port == port,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              kind.matches(path: url.path) else {
            throw CDPError.invalidEndpoint
        }
        return url
    }

    private static func isLoopbackHTTPURL(_ url: URL, path: String, port: Int) -> Bool {
        url.scheme?.lowercased() == "http" &&
            isLoopbackHost(url.host) &&
            url.port == port &&
            url.user == nil &&
            url.password == nil &&
            url.path == path &&
            url.query == nil &&
            url.fragment == nil
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        host?.lowercased() == ChromiumLaunchArguments.loopbackAddress
    }

    private struct VersionPayload: Decodable {
        let webSocketDebuggerURL: URL?

        enum CodingKeys: String, CodingKey {
            case webSocketDebuggerURL = "webSocketDebuggerUrl"
        }
    }

    private struct TargetPayload: Decodable {
        let id: String
        let type: String
        let url: String
        let webSocketDebuggerURL: String?

        enum CodingKeys: String, CodingKey {
            case id, type, url
            case webSocketDebuggerURL = "webSocketDebuggerUrl"
        }
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}
