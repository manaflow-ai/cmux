import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextPages
import CmuxNextSettings
import Foundation

extension InternalPageID {
    static let artifacts = InternalPageID(rawValue: "artifacts")
}

/// Piece 4's read-only Artifacts page. The host owns the cmux bearer and proxies only the three
/// read operations needed by the page; no Artifacts/git token ever crosses this boundary.
enum ArtifactsPageTab {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(WebPageTab(.artifacts, symbol: "shippingbox", title: "Artifacts") { [weak services] in
            guard let services else { return nil }
            let provider = ArtifactsPageProvider(auth: services.cloud.auth, baseURL: artifactsBaseURL())
            return PageWebView(descriptor: .artifacts, routes: [PageRoute(prefix: "cmux.artifacts.", provider: provider)])
        })
        registry.bind("artifacts.show", unavailable: { [weak services] in
            services?.settings?.snapshot.previewFeatures == true ? nil : "Artifacts is a Labs preview. Turn on Settings > Advanced > Labs > Show Preview Features."
        }, invoke: { [weak services] _ in
            guard let services, services.settings?.snapshot.previewFeatures == true else { return }
            _ = services.pages.show(.artifacts, in: services.windows.active, focus: true)
        })
    }

    private static func artifactsBaseURL() -> URL {
        if let value = ProcessInfo.processInfo.environment["CMUX_NEXT_ARTIFACTS_API_URL"], let url = URL(string: value) { return url }
        return URL(string: "https://cmux-platform-development.debussy.workers.dev")!
    }
}

@MainActor
private final class ArtifactsPageProvider: PageProvider {
    private let auth: CloudAuth
    private let baseURL: URL
    init(auth: CloudAuth, baseURL: URL) { self.auth = auth; self.baseURL = baseURL }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.artifacts.tree": return try await request("GET", "/v1/artifacts/tree", query: ["ref": params["ref"]?.stringValue ?? "main", "path": params["path"]?.stringValue ?? ""])
        case "cmux.artifacts.history": return try await request("GET", "/v1/artifacts/history", query: ["ref": params["ref"]?.stringValue ?? "main", "path": params["path"]?.stringValue ?? "", "limit": "50"])
        case "cmux.artifacts.file":
            let result = try await requestBytes("/v1/artifacts/file", query: ["ref": params["ref"]?.stringValue ?? "main", "path": params["path"]?.stringValue ?? ""])
            let type = result.response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            let text = String(data: result.data, encoding: .utf8) ?? result.data.base64EncodedString()
            return ["path": .string(params["path"]?.stringValue ?? ""), "content": .string(text), "contentType": .string(type), "commit": .string(result.response.value(forHTTPHeaderField: "X-Artifacts-Commit") ?? "")]
        default: throw PageError.unknownOp(op)
        }
    }

    private func request(_ method: String, _ path: String, query: [String: String]) async throws -> JSONValue {
        let (data, _) = try await requestData(method, path, query: query)
        return try JSONValue.parse(data)
    }

    private func requestBytes(_ path: String, query: [String: String]) async throws -> (Data, HTTPURLResponse) {
        try await requestData("GET", path, query: query)
    }

    private func requestData(_ method: String, _ path: String, query: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let access = try await auth.tokens().access
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PageError(code: "cmux.artifacts.unavailable", message: "Artifacts could not be loaded.", retryable: true) }
        return (data, http)
    }
}
