import Foundation

struct DeviceRegistration: Codable {
    let deviceId: String
    let hostname: String
    let tailscaleHostname: String?
    let sshPort: Int
    let capabilities: [String]
    let osVersion: String
    let appVersion: String
}

struct TerminalEvent: Codable {
    let deviceId: String
    let type: String
    let title: String
    let body: String?
    let workspaceId: String?
}

struct WorkspaceSnapshot: Codable {
    let id: String
    let title: String
    let surfaceCount: Int
    let hasActivity: Bool
}

private struct ConvexMutationBody<A: Encodable>: Encodable {
    let path: String
    let args: A
}

/// HTTP client for Convex backend API calls (device registration, events, workspace sync).
/// Uses URLSession for async HTTP. Auth via Bearer token (API key).
final class ConvexHTTPClient: @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func registerDevice(_ device: DeviceRegistration) async throws {
        try await mutation("devices:register", args: device)
    }

    func heartbeat(deviceId: String) async throws {
        try await mutation("devices:heartbeat", args: ["deviceId": deviceId])
    }

    func markOffline(deviceId: String) async throws {
        try await mutation("devices:markOffline", args: ["deviceId": deviceId])
    }

    func sendEvent(_ event: TerminalEvent) async throws {
        try await mutation("events:send", args: event)
    }

    func syncWorkspaces(deviceId: String, workspaces: [WorkspaceSnapshot]) async throws {
        struct SyncArgs: Encodable {
            let deviceId: String
            let workspaces: [WorkspaceSnapshot]
        }
        try await mutation("devices:syncWorkspaces", args: SyncArgs(
            deviceId: deviceId,
            workspaces: workspaces
        ))
    }

    // MARK: - Transport

    private func mutation<T: Encodable>(_ path: String, args: T) async throws {
        let url = baseURL.appendingPathComponent("api/mutation")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = ConvexMutationBody(path: path, args: args)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConvexError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ConvexError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func mutation(_ path: String, args: [String: Any]) async throws {
        let url = baseURL.appendingPathComponent("api/mutation")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["path": path, "args": args]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConvexError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ConvexError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }
}

enum ConvexError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Convex"
        case .httpError(let statusCode, let message):
            return "Convex HTTP \(statusCode): \(message)"
        }
    }
}
