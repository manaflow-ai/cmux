public import Foundation

/// Ships the credential-lifecycle slice of the transport journal to the
/// authenticated `/api/observability/transport` route, so wedge evidence
/// survives the Mac's short unified-log retention. Data-plane chatter never
/// leaves the device: only allowlisted components pass, minus an explicit
/// event denylist for the periodic ones.
public actor IrxJournalUploader {
    public struct ClientMetadata: Sendable {
        public var platform: String
        public var clientChannel: String
        public var appVersion: String?
        public var buildNumber: String?
        public var bundleIdentifier: String?
        public var osVersion: String?
        /// 12-hex endpoint prefix; matches client journal and server sink rows.
        public var endpoint: String?
        public var deviceId: String?
        public var buildTag: String?

        public init(
            platform: String, clientChannel: String, appVersion: String? = nil,
            buildNumber: String? = nil, bundleIdentifier: String? = nil, osVersion: String? = nil,
            endpoint: String? = nil, deviceId: String? = nil, buildTag: String? = nil
        ) {
            self.platform = platform
            self.clientChannel = clientChannel
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.bundleIdentifier = bundleIdentifier
            self.osVersion = osVersion
            self.endpoint = endpoint
            self.deviceId = deviceId
            self.buildTag = buildTag
        }
    }

    /// Components worth durable retention: the credential-renewal pipeline,
    /// connection lifecycle, and admission. Everything else stays local.
    public static let exportedComponents: Set<String> = [
        "v2-control", "v2-host", "v2-lifecycle", "endpoint", "admission",
        "host-runtime", "engine", "broker", "control-plane", "legacy-dialect",
        "connection", "client-runtime", "registry", "host-events", "device-list",
    ]
    /// Periodic events inside exported components that would dominate volume
    /// without adding wedge evidence.
    public static let deniedEvents: Set<String> = [
        "pong-sent", "ponged", "pong", "hint-update", "discovered", "acked",
        "directory", "lane-accepted",
    ]

    public static let maximumBatch = 100
    private static let bufferCapacity = 500
    private static let flushThreshold = 50

    private let endpoint: URL
    private let metadata: ClientMetadata
    private let token: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let transport: @Sendable (URLRequest) async throws -> Int
    private let flushInterval: TimeInterval
    private var buffer: [[String: Any]] = []
    private var flushTask: Task<Void, Never>?
    private var stopped = false
    public private(set) var droppedCount = 0
    public private(set) var uploadedCount = 0

    /// - Parameters:
    ///   - endpoint: The complete transport-journal ingest URL.
    ///   - metadata: Attribution attached to every exported event.
    ///   - token: Bearer credential provider; `true` forces a refresh.
    ///   - transport: Executes the request and returns the HTTP status.
    ///   - flushInterval: Idle time before a partial batch ships.
    public init(
        endpoint: URL,
        metadata: ClientMetadata,
        token: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
        transport: @escaping @Sendable (URLRequest) async throws -> Int,
        flushInterval: TimeInterval = 30
    ) {
        self.endpoint = endpoint
        self.metadata = metadata
        self.token = token
        self.transport = transport
        self.flushInterval = flushInterval
    }

    /// Journal-tap entry point; synchronous and non-blocking by contract.
    public nonisolated func offer(_ event: IrxJournalEvent) {
        guard Self.exportedComponents.contains(event.component),
              !Self.deniedEvents.contains(event.event) else { return }
        Task { await self.enqueue(event) }
    }

    public func stop() {
        stopped = true
        flushTask?.cancel()
        flushTask = nil
        buffer.removeAll()
    }

    /// Ships everything currently buffered; used by tests and shutdown paths.
    public func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        await flush()
    }

    private func enqueue(_ event: IrxJournalEvent) async {
        guard !stopped else { return }
        buffer.append(wire(event))
        if buffer.count > Self.bufferCapacity {
            droppedCount += buffer.count - Self.bufferCapacity
            buffer.removeFirst(buffer.count - Self.bufferCapacity)
        }
        if buffer.count >= Self.flushThreshold {
            flushTask?.cancel()
            flushTask = nil
            await flush()
            return
        }
        guard flushTask == nil else { return }
        let interval = flushInterval
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) }
            catch { return }
            await self?.scheduledFlush()
        }
    }

    private func scheduledFlush() async {
        flushTask = nil
        await flush()
    }

    private func flush() async {
        guard !stopped, !buffer.isEmpty else { return }
        let batch = Array(buffer.prefix(Self.maximumBatch))
        buffer.removeFirst(batch.count)
        guard let body = try? JSONSerialization.data(withJSONObject: ["batch": batch]) else {
            droppedCount += batch.count
            return
        }
        var status = await post(body: body, forceToken: false)
        guard !stopped else { return }
        if status == 401 {
            status = await post(body: body, forceToken: true)
            guard !stopped else { return }
        }
        switch status {
        case 200..<300:
            uploadedCount += batch.count
        case 400, 404, 413:
            // The server rejected the batch shape, or this backend does not
            // serve the route yet; retrying this batch cannot succeed. Later
            // batches still try, so the lane comes up when the route ships.
            droppedCount += batch.count
        default:
            // Auth outage, rate limit, or transport failure: retain for the
            // next flush, bounded by the buffer capacity.
            buffer.insert(contentsOf: batch, at: 0)
            if buffer.count > Self.bufferCapacity {
                droppedCount += buffer.count - Self.bufferCapacity
                buffer.removeLast(buffer.count - Self.bufferCapacity)
            }
        }
        if !buffer.isEmpty, flushTask == nil, !stopped {
            let interval = flushInterval
            flushTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                await self?.scheduledFlush()
            }
        }
    }

    private func post(body: Data, forceToken: Bool) async -> Int {
        guard !stopped else { return -1 }
        guard let credential = try? await token(forceToken) else { return -1 }
        guard !stopped else { return -1 }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let status = (try? await transport(request)) ?? -1
        guard !stopped else { return -1 }
        return status
    }

    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func wire(_ event: IrxJournalEvent) -> [String: Any] {
        var value: [String: Any] = [
            "timestamp": timestampFormatter.string(from: event.wallTime),
            "monoMs": event.monotonicMs,
            "component": event.component,
            "event": event.event,
            "platform": metadata.platform,
            "clientChannel": metadata.clientChannel,
        ]
        if let appVersion = metadata.appVersion { value["appVersion"] = appVersion }
        if let buildNumber = metadata.buildNumber { value["buildNumber"] = buildNumber }
        if let bundleIdentifier = metadata.bundleIdentifier { value["bundleIdentifier"] = bundleIdentifier }
        if let osVersion = metadata.osVersion { value["osVersion"] = osVersion }
        if let endpoint = metadata.endpoint { value["endpoint"] = endpoint }
        if let deviceId = metadata.deviceId { value["deviceId"] = deviceId }
        if let buildTag = metadata.buildTag { value["buildTag"] = buildTag }
        if !event.attributes.isEmpty {
            // Server-side caps: 16 keys, snake-case keys, 160-char values.
            var attributes: [String: String] = [:]
            for (key, item) in event.attributes.sorted(by: { $0.key < $1.key }).prefix(16) {
                let normalized = key.lowercased().replacingOccurrences(
                    of: "[^a-z0-9_]", with: "_", options: .regularExpression)
                guard !normalized.isEmpty, normalized.count <= 32 else { continue }
                guard !item.isEmpty else { continue }
                attributes[normalized] = String(item.prefix(160))
            }
            if !attributes.isEmpty { value["attributes"] = attributes }
        }
        return value
    }
}
