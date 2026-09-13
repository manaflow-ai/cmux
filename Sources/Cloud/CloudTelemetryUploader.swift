import CmuxAuthRuntime
import CryptoKit
import Foundation
import os

/// A bounded, account-scoped queue. Uses its own transport, so export errors cannot recurse.
actor CloudTelemetryUploader: CloudTelemetrySending {
    private struct Entry: Codable {
        let accountKey: String
        let client: CloudTelemetryClient
        let span: CloudTelemetrySpan
    }
    private struct Batch: Encodable {
        let version = 1
        let client: CloudTelemetryClient
        let spans: [CloudTelemetrySpan]
    }
    private struct Receipt: Decodable { let eventIds: [String] }
    private let auth: AuthCoordinator
    private let session: URLSession
    private let baseURL: URL
    private let client: CloudTelemetryClient
    private let queueURL: URL
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "CloudDiagnostics")
    private var entries: [Entry] = []
    private var loaded = false
    private var uploadTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var droppedCount = 0

    init(
        auth: AuthCoordinator,
        baseURL: URL,
        client: CloudTelemetryClient,
        session: URLSession = URLSession(configuration: .ephemeral),
        queueURL: URL? = nil
    ) {
        self.auth = auth
        self.baseURL = baseURL
        self.client = client
        self.session = session
        self.queueURL = queueURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app")
            .appendingPathComponent("cloud-diagnostics.json")
    }

    deinit { uploadTask?.cancel() }

    func enqueue(_ original: CloudTelemetrySpan, identity: AuthenticatedSessionIdentity) async {
        guard await auth.isAuthenticatedSessionIdentityCurrent(identity) else { return }
        loadIfNeeded()
        let accountKey = Self.accountKey(identity.accountID)
        entries.removeAll { $0.accountKey != accountKey || $0.span.endedAtMs < Self.nowMs - 86_400_000 }
        // Production polling retains a deterministic 2% sample of successful detail.
        // Every root outcome and every failure remains available as a denominator or error.
        if client.channel == "production", original.outcome == .success,
           [.list, .status, .stats, .refresh].contains(original.operation), original.phase != .operation,
           (UInt64(original.traceId.suffix(4), radix: 16) ?? 0) % 50 != 0 { return }
        var span = original
        if droppedCount > 0 { span.droppedCount = min(droppedCount, 1_000_000); droppedCount = 0 }
        entries.append(Entry(accountKey: accountKey, client: client, span: span))
        while entries.count > 2000 {
            let index = entries.firstIndex { $0.span.outcome == .success } ?? 0
            entries.remove(at: index)
            droppedCount += 1
        }
        if span.outcome == .failure || span.outcome == .timeout { persist() }
        schedule()
    }

    func clearForSignOut() {
        generation &+= 1
        uploadTask?.cancel()
        uploadTask = nil
        entries.removeAll()
        droppedCount = 0
        loaded = true
        persist()
    }

    private func schedule() {
        guard uploadTask == nil else { return }
        let currentGeneration = generation
        uploadTask = Task { [weak self] in
            // Batch cadence, not a UI synchronization delay.
            try? await Task.sleep(for: .seconds(2))
            await self?.drain(generation: currentGeneration)
        }
    }

    private func drain(generation currentGeneration: UInt64) async {
        persist()
        defer { if generation == currentGeneration { uploadTask = nil } }
        var failures = 0
        while !Task.isCancelled, generation == currentGeneration, !entries.isEmpty {
            guard let identity = await auth.authenticatedSessionIdentity else { return }
            let key = Self.accountKey(identity.accountID)
            entries.removeAll { $0.accountKey != key || $0.span.endedAtMs < Self.nowMs - 86_400_000 }
            guard let first = entries.first else { persist(); return }
            let batchEntries = Array(entries.lazy.filter { $0.client == first.client }.prefix(40))
            let ids = Set(batchEntries.map { $0.span.eventId })
            do {
                let tokens = try await auth.currentTokens()
                guard await auth.isAuthenticatedSessionIdentityCurrent(identity), generation == currentGeneration else { return }
                var request = URLRequest(url: baseURL.appendingPathComponent("api/observability/cloud"))
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
                request.httpBody = try JSONEncoder().encode(Batch(client: first.client, spans: batchEntries.map(\.span)))
                let (data, response) = try await session.data(for: request)
                guard generation == currentGeneration, await auth.isAuthenticatedSessionIdentityCurrent(identity) else { return }
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if response.statusCode == 202 {
                    let receipt = try JSONDecoder().decode(Receipt.self, from: data)
                    guard Set(receipt.eventIds) == ids else { throw URLError(.badServerResponse) }
                    entries.removeAll { ids.contains($0.span.eventId) }
                    persist()
                    failures = 0
                    continue
                }
                if [400, 409, 413, 415].contains(response.statusCode) {
                    // A permanently rejected record must not block later errors forever.
                    entries.removeAll { ids.contains($0.span.eventId) }
                    droppedCount += ids.count
                    persist()
                    logger.error("Cloud diagnostic batch rejected, status=\(response.statusCode) count=\(ids.count)")
                    continue
                }
                throw URLError(.badServerResponse)
            } catch {
                if Task.isCancelled || generation != currentGeneration { return }
                failures += 1
                logger.error("Cloud diagnostic upload pending, attempt=\(failures) queued=\(self.entries.count)")
                try? await Task.sleep(for: .seconds(min(600, 60 * failures)))
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        do {
            guard FileManager.default.fileExists(atPath: queueURL.path) else { return }
            let size = try queueURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2 * 1024 * 1024 else { droppedCount += 1; return }
            entries = Array(try JSONDecoder().decode([Entry].self, from: Data(contentsOf: queueURL)).suffix(2000))
        } catch {
            droppedCount += 1
            logger.error("Cloud diagnostic queue could not be read")
        }
    }

    private func persist() {
        do {
            let directory = queueURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(entries)
            try data.write(to: queueURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: queueURL.path)
        } catch {
            logger.error("Cloud diagnostic queue could not be saved")
        }
    }

    private static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func accountKey(_ id: String) -> String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }
}
