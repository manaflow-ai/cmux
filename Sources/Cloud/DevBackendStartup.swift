import Foundation
import Observation

/// Owns the optional development-backend status stream for a visible Cloud
/// panel. Production builds never open this diagnostic route.
@MainActor @Observable
final class DevBackendStartup {
    private(set) var status: Status?
    private(set) var attempt = 0
    private let diagnosticsEnvironment: [String: String]
    private let session: URLSession
    private let configuredEndpoint: URL?
    private let emit: @Sendable (DevBackendDiagnostics.Event) async -> Void

    init(endpoint: URL? = nil, session: URLSession = .shared,
         diagnosticsEnvironment: [String: String] = ProcessInfo.processInfo.environment,
         emit: @escaping @Sendable (DevBackendDiagnostics.Event) async -> Void = { await DevBackendDiagnostics.shared.record($0) }) {
        self.configuredEndpoint = endpoint ?? Self.endpoint
        self.diagnosticsEnvironment = diagnosticsEnvironment
        self.session = session
        self.emit = emit
    }

    private enum StreamError: Error { case http(Int) }

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
                throw URLError(.timedOut)
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
        guard let endpoint = configuredEndpoint else { status = nil; return }
        let startedAt = Date()
        let clock = ContinuousClock.now
        func report(_ outcome: String, error: Error? = nil) async {
            let duration = clock.duration(to: .now).components
            let milliseconds = Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
            let httpStatus: Int?
            if let failure = error as? StreamError, case let .http(code) = failure { httpStatus = code } else { httpStatus = nil }
            if let event = DevBackendDiagnostics.event(outcome: outcome, startedAt: startedAt, durationMs: milliseconds,
                                                       attempt: attempt, errorNumber: (error as? URLError)?.code.rawValue, httpStatus: httpStatus, environment: diagnosticsEnvironment) {
                await emit(event)
            }
        }
        status = Status(state: "checking", message: String(localized: "devBackend.checking", defaultValue: "Connecting to your development backend…"))
        do {
            try await Self.withDeadline(.seconds(240)) { [weak self] in
                try await self?.observeStream(endpoint: endpoint)
            }
            if status?.isFailure == true {
                await report("startup_failed")
            } else if status?.isReady == true {
                await report("ready")
            }
            // A nil status is the supported legacy 404 fallback, not a failed stream.
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .timedOut {
            guard !Task.isCancelled else { return }
            status = Status(state: "failed", message: String(localized: "devBackend.timeout", defaultValue: "The development backend took too long to start. Try again."))
            await report("timeout", error: error)
        } catch {
            guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
            status = Status(state: "failed", message: String(localized: "devBackend.unreachable", defaultValue: "Cannot reach the development backend. Check that Tailscale is connected, then try again."))
            await report(error is StreamError || error is DecodingError ? "invalid_response" : "unreachable", error: error)
        }
    }

    private func observeStream(endpoint: URL) async throws {
        var request = URLRequest(url: endpoint)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // An older retained build may still have a direct route. Its normal
        // VM request remains authoritative if the gateway route is absent.
        if response.statusCode == 404 { status = nil; return }
        guard response.statusCode == 200 else { throw StreamError.http(response.statusCode) }
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
