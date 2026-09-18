import Foundation
import Observation

/// Owns the optional development-backend status stream for a visible Cloud
/// panel. Production builds never open this diagnostic route.
@MainActor @Observable
final class DevBackendStartup {
    enum StartupError: Error {
        case timedOut
    }

    struct Status: Decodable, Equatable {
        let state: String
        let message: String
        var isFailure: Bool { state == "failed" }
        var isReady: Bool { state == "ready" }
    }

    private(set) var status: Status?
    private(set) var attempt = 0

    /// URLRequest's timeout is an idle timeout for a streaming response. This
    /// race supplies the total deadline so heartbeats cannot leave the panel in
    /// a permanent loading state.
    static func withDeadline<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await sleep(timeout)
                throw StartupError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    static var endpoint: URL? {
        #if DEBUG
        guard CmuxFeatureFlagOverrideCapability().enablesCloudDogfood else { return nil }
        let base = AuthEnvironment.vmAPIBaseURL
        guard base.scheme == "https",
              base.host == "cmux-dev-backend-1.tail137216.ts.net",
              let port = base.port, (3800...4799).contains(port) else { return nil }
        return base.appendingPathComponent("__cmux_backend/events")
        #else
        return nil
        #endif
    }

    func retry() { attempt += 1 }

    func observe() async {
        guard let endpoint = Self.endpoint else { status = nil; return }
        status = Status(state: "checking", message: String(localized: "devBackend.checking", defaultValue: "Connecting to your development backend…"))
        do {
            try await Self.withDeadline(.seconds(240)) { [weak self] in
                try await self?.observeStream(endpoint: endpoint)
            }
        } catch is CancellationError {
            return
        } catch is StartupError {
            guard !Task.isCancelled else { return }
            status = Status(state: "failed", message: String(localized: "devBackend.timeout", defaultValue: "The development backend took too long to start. Try again."))
        } catch {
            guard !Task.isCancelled else { return }
            status = Status(state: "failed", message: String(localized: "devBackend.unreachable", defaultValue: "Cannot reach the development backend. Check that Tailscale is connected, then try again."))
        }
    }

    private func observeStream(endpoint: URL) async throws {
        var request = URLRequest(url: endpoint)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // An older retained build may still have a direct route. Its normal
        // VM request remains authoritative if the gateway route is absent.
        if response.statusCode == 404 { status = nil; return }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: "), let data = String(line.dropFirst(6)).data(using: .utf8) else { continue }
            let next = try JSONDecoder().decode(Status.self, from: data)
            status = next
            if next.isReady || next.isFailure { return }
        }
        if status?.isReady != true && status?.isFailure != true { throw URLError(.networkConnectionLost) }
    }
}
