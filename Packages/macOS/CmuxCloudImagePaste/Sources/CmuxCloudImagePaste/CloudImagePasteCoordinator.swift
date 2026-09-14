public import Foundation

/// Owns one cancellable image transaction on the current leased attachment.
/// Acknowledged chunks bound transport memory and prevent a commit overtaking data.
@MainActor
public final class CloudImagePasteCoordinator {
    /// The daemon capability required for Cloud image paste.
    public nonisolated static let capability = "terminal-image-paste-v1"
    /// The maximum acknowledged payload sent in one control request.
    public nonisolated static let chunkBytes = 48 * 1024
    /// Sends an authenticated control command and returns its request ID.
    public typealias Send = @MainActor ([String: Any]) throws -> UInt64

    private struct Endpoint {
        let generation = UUID()
        let terminalID: String
        let surfaceID: UInt64
        let lease: String
        let send: Send
    }
    private struct Pending {
        let requestID: UInt64
        let token: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var endpoint: Endpoint?
    private var supportsImages = false
    private var attached = false
    private var pending: Pending?
    private var activeToken: UUID?
    private var committing = false
    private var preparing = false
    private var terminalError: (token: UUID, error: any Error)?
    private let deadline: Duration
    private let clock: any Clock<Duration>
    private var deadlineTimer: CloudImagePasteDeadline?
    /// The number of image bytes acknowledged by the daemon for the active upload.
    private var transferredBytes = 0

    /// Creates a coordinator with an injected, cancellation-aware deadline.
    ///
    /// - Parameters:
    ///   - deadline: Maximum time allowed for one upload transaction.
    ///   - clock: Clock used to enforce the upload deadline.
    public init(deadline: Duration = .seconds(120), clock: any Clock<Duration> = ContinuousClock()) {
        self.deadline = deadline
        self.clock = clock
    }

    /// Binds the coordinator to the current authenticated terminal attachment.
    public func bind(
        terminalID: String,
        surfaceID: UInt64,
        lease: String?,
        capabilities: Set<String>,
        send: @escaping Send
    ) {
        disconnect()
        attached = true
        supportsImages = capabilities.contains(Self.capability)
        if let lease, !lease.isEmpty {
            endpoint = Endpoint(terminalID: terminalID, surfaceID: surfaceID, lease: lease, send: send)
        }
    }

    /// Throws when the current attachment cannot accept Cloud images.
    public func requireAvailable() throws {
        guard attached else { throw CloudImagePasteError.unavailable }
        guard supportsImages else { throw CloudImagePasteError.unsupported }
        guard endpoint != nil else { throw CloudImagePasteError.unavailable }
    }

    /// Reserve before filesystem I/O so another paste cannot replace its Cancel UI.
    /// Reserves the attachment while clipboard bytes are materialized.
    public func beginPreparation() throws -> UUID {
        try requireAvailable()
        guard !preparing, activeToken == nil, let endpoint else { throw CloudImagePasteError.busy }
        preparing = true
        return endpoint.generation
    }

    /// Releases the clipboard materialization reservation.
    public func endPreparation() { preparing = false }

    /// Retires the attachment and fails any pending request.
    public func disconnect() {
        endpoint = nil
        attached = false
        supportsImages = false
        failPending(committing ? CloudImagePasteError.deliveryUncertain : CloudImagePasteError.unavailable)
    }

    /// Image responses are consumed before the mirror's diagnostic logger sees them.
    /// Consumes one daemon response before it reaches diagnostic logging.
    public func receive(requestID: UInt64, ok: Bool, accepted: Bool? = true, error: String?) -> Bool {
        guard let pending, pending.requestID == requestID else { return false }
        self.pending = nil
        if ok && accepted == true { pending.continuation.resume() }
        else if ok && committing { pending.continuation.resume(throwing: CloudImagePasteError.deliveryUncertain) }
        else { pending.continuation.resume(throwing: CloudImagePasteError(serverCode: error)) }
        return true
    }

    /// Uploads and brackets one validated image through the leased terminal.
    ///
    /// - Parameters:
    ///   - image: Validated clipboard image bytes.
    ///   - generation: Optional preparation generation used to fence a
    ///     reconnect or replacement surface.
    /// - Throws: ``CloudImagePasteError`` when the link, daemon, or upload is
    ///   unavailable.
    public func paste(_ image: CloudClipboardImage, generation: UUID? = nil) async throws {
        try requireAvailable()
        try Task.checkCancellation()
        guard activeToken == nil, let endpoint else { throw CloudImagePasteError.busy }
        guard generation == nil || generation == endpoint.generation else { throw CloudImagePasteError.unavailable }
        let token = UUID()
        let uploadID = token.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        activeToken = token
        committing = false
        transferredBytes = 0
        terminalError = nil
        let deadlineTimer = CloudImagePasteDeadline(duration: deadline, clock: clock) { [weak self] in
            self?.cancel(token: token, error: CloudImagePasteError.timedOut)
        }
        self.deadlineTimer = deadlineTimer
        defer {
            deadlineTimer.cancel()
            self.deadlineTimer = nil
            terminalError = nil
            activeToken = nil
            committing = false
        }
        do {
            try await withTaskCancellationHandler {
                try await request(endpoint, uploadID: uploadID, token: token,
                                  fields: ["op": "begin", "mime": image.mime, "size": image.data.count])
                while transferredBytes < image.data.count {
                    try Task.checkCancellation()
                    let end = min(transferredBytes + Self.chunkBytes, image.data.count)
                    let chunk = image.data.subdata(in: transferredBytes..<end)
                    try await request(endpoint, uploadID: uploadID, token: token, fields: [
                        "op": "chunk", "offset": transferredBytes, "data": chunk.base64EncodedString()
                    ])
                    transferredBytes = end
                }
                try Task.checkCancellation()
                committing = true
                try await request(endpoint, uploadID: uploadID, token: token, fields: ["op": "commit"])
            } onCancel: { [weak self] in
                Task { @MainActor in self?.cancel(token: token, error: CancellationError()) }
            }
        } catch {
            if !committing { sendCancel(endpoint, uploadID: uploadID) }
            throw error
        }
    }

    private func request(_ endpoint: Endpoint, uploadID: String, token: UUID, fields: [String: Any]) async throws {
        try Task.checkCancellation()
        guard self.endpoint?.generation == endpoint.generation, activeToken == token else { throw CloudImagePasteError.unavailable }
        if let terminalError, terminalError.token == token {
            throw terminalError.error
        }
        try await withCheckedThrowingContinuation { continuation in
            do {
                let requestID = try endpoint.send(command(endpoint, uploadID: uploadID, fields: fields))
                pending = Pending(requestID: requestID, token: token, continuation: continuation)
            } catch {
                continuation.resume(throwing: committing ? CloudImagePasteError.deliveryUncertain : CloudImagePasteError.unavailable)
            }
        }
    }

    private func command(_ endpoint: Endpoint, uploadID: String, fields: [String: Any]) -> [String: Any] {
        fields.merging([
            "cmd": "paste-image", "surface": endpoint.surfaceID,
            "terminal_id": endpoint.terminalID, "lease": endpoint.lease, "upload_id": uploadID
        ]) { _, identity in identity }
    }

    private func sendCancel(_ endpoint: Endpoint, uploadID: String) {
        _ = try? endpoint.send(command(endpoint, uploadID: uploadID, fields: ["op": "cancel"]))
    }

    private func cancel(token: UUID, error: any Error) {
        guard activeToken == token else { return }
        let terminalError = committing ? CloudImagePasteError.deliveryUncertain : error
        self.terminalError = (token, terminalError)
        failPending(terminalError)
    }

    private func failPending(_ error: any Error) {
        let previous = pending
        pending = nil
        previous?.continuation.resume(throwing: error)
    }
}
