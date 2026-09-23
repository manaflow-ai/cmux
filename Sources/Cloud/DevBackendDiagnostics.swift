import Foundation
import os

/// The dev app owns its own bounded outbox. No host watcher or GCP dependency.
actor DevBackendDiagnostics {
    struct Event: Codable, Sendable, Equatable {
        let eventId: String
        let tag: String
        let revision: String
        let startedAtMs: Int64
        let durationMs: Int
        let attempt: Int
        let outcome: String
        let errorNumber: Int?
        let httpStatus: Int?
    }
    private struct Batch: Encodable { let version = 1; let events: [Event] }
    private struct Receipt: Decodable { let eventIds: [String] }
    typealias Sender = @Sendable ([Event]) async throws -> Void

    static let shared = DevBackendDiagnostics(
        queueURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app")
            .appendingPathComponent("dev-backend-diagnostics.json"),
        enabled: enabledForCurrentLaunch
    )
    private static var enabledForCurrentLaunch: Bool {
        #if DEBUG
        return BuildFlavor.current == .dev && TelemetrySettings.enabledForCurrentLaunch
            && !MacSentryStartupPolicy.isRunningUnderXCTest(environment: ProcessInfo.processInfo.environment)
        #else
        return false
        #endif
    }

    private let queueURL: URL
    private let enabled: Bool
    private let automaticallyFlush: Bool
    private let sender: Sender
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "DevBackendDiagnostics")
    private var entries: [Event] = []
    private var loaded = false
    private var uploadTask: Task<Void, Never>?
    private var flushing = false

    init(queueURL: URL, enabled: Bool, automaticallyFlush: Bool = true, sender: @escaping Sender = send) {
        self.queueURL = queueURL
        self.enabled = enabled
        self.automaticallyFlush = automaticallyFlush
        self.sender = sender
    }

    deinit { uploadTask?.cancel() }

    static func event(outcome: String, startedAt: Date, durationMs: Int, attempt: Int, errorNumber: Int? = nil, httpStatus: Int? = nil,
                      environment: [String: String] = ProcessInfo.processInfo.environment,
                      info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> Event? {
        let tag = environment["CMUX_TAG"] ?? (info["LSEnvironment"] as? [String: String])?["CMUX_TAG"] ?? ""
        guard tag.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else { return nil }
        let revision = info["CMUXCommit"] as? String ?? "unknown"
        return Event(eventId: UUID().uuidString.lowercased(), tag: tag,
                     revision: revision.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) == nil ? "unknown" : revision,
                     startedAtMs: Int64(startedAt.timeIntervalSince1970 * 1000),
                     durationMs: min(3_600_000, max(0, durationMs)), attempt: min(10_000, max(0, attempt)), outcome: outcome,
                     errorNumber: errorNumber, httpStatus: httpStatus)
    }

    func record(_ event: Event) {
        guard enabled else { return }
        load()
        entries.removeAll { $0.startedAtMs < Self.nowMs - 86_400_000 }
        entries.append(event)
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
        persist()
        if event.outcome != "ready" {
            logger.error("Development backend failed outcome=\(event.outcome, privacy: .public) code=\(event.errorNumber ?? 0) event=\(event.eventId, privacy: .public)")
        }
        startUploadIfNeeded()
    }

    private func startUploadIfNeeded() {
        guard automaticallyFlush, uploadTask == nil, !entries.isEmpty else { return }
        uploadTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if await self.flushOnce() { break }
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
            await self.uploadFinished()
        }
    }

    private func uploadFinished() {
        uploadTask = nil
        startUploadIfNeeded()
    }

    /// True only when all retained events were acknowledged or expired.
    func flushOnce() async -> Bool {
        guard enabled, !flushing else { return false }
        load()
        flushing = true
        defer { flushing = false }
        entries.removeAll { $0.startedAtMs < Self.nowMs - 86_400_000 }
        while !entries.isEmpty, !Task.isCancelled {
            let batch = Array(entries.prefix(20))
            do {
                try await sender(batch)
                let ids = Set(batch.map(\.eventId))
                entries.removeAll { ids.contains($0.eventId) }
                persist()
            } catch {
                logger.notice("Development diagnostics retained pending=\(self.entries.count)")
                return false
            }
        }
        persist()
        return entries.isEmpty
    }

    var pendingCount: Int { load(); return entries.count }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let size = try? queueURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128 * 1024,
              let data = try? Data(contentsOf: queueURL), let retained = try? JSONDecoder().decode([Event].self, from: data) else { return }
        entries = Array(retained.suffix(100))
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(entries).write(to: queueURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: queueURL.path)
        } catch { logger.error("Development diagnostic outbox could not be saved") }
    }

    private static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func send(_ events: [Event]) async throws {
        // Public, fixed-schema ingress is independent of sign-in and GCP.
        // Ingestion credentials stay on the server, never in the app bundle.
        var request = URLRequest(url: URL(string: "https://cmux.com/api/observability/dev-backend")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Batch(events: events))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 202,
              Set(try JSONDecoder().decode(Receipt.self, from: data).eventIds) == Set(events.map(\.eventId)) else {
            throw URLError(.badServerResponse)
        }
    }
}
