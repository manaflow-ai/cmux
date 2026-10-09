import CmuxMobileWire
import Foundation

/// `read` ops over one shared `rpc` channel per session generation
/// (a0-rpc.md section 3.4; first reader: C4 `files.list`, `files.roots`).
/// Replies are matched by id; an `error` reply throws `.refused`, a lost
/// channel throws `.linkLost`, and cancelling the caller settles its read.
extension MobileLinkClient {
    public func read(_ op: String, params: JSONValue) async throws -> JSONValue {
        let channel = try await rpcChannel()
        let id = nextReadID
        nextReadID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingReads[id] = continuation
                Task {
                    do {
                        try await channel.send(frame: .read(ReadFrame(id: id, op: op, params: params)))
                    } catch {
                        self.settleRead(id, .failure(MobileLinkClientError.linkLost))
                    }
                }
            }
        } onCancel: {
            Task { await self.settleRead(id, .failure(CancellationError())) }
        }
    }

    func rpcChannel() async throws -> MobileChannel {
        if let rpc, rpc.generation == currentGeneration { return rpc.channel }
        if let rpcOpening { return try await rpcOpening.value }
        let opening = Task { () throws -> MobileChannel in
            let opened = try await self.open(MobileChannelRequest(kind: .rpc, channelClass: .interactive, window: 64 * 1024,
                                                                  params: [:], stream: "rpc", priority: .control))
            await self.adoptRPC(opened)
            return opened.channel
        }
        rpcOpening = opening
        defer { rpcOpening = nil }
        return try await opening.value
    }

    private func adoptRPC(_ opened: MobileOpenedChannel) {
        rpc = (opened.channel, opened.generation)
        let generation = opened.generation
        Task { await self.readReplies(opened.channel, generation: generation) }
    }

    private func readReplies(_ channel: MobileChannel, generation: UInt64) async {
        while true {
            switch await channel.receive() {
            case .json(let value):
                switch try? MobileFrame(value: value) {
                case .readResult(let result)?:
                    settleRead(result.id, .success(result.value))
                case .result(let result)?:
                    let revision = UInt64(result.revision) ?? 0
                    settleOperation(result.idempotencyKey,
                                    .success(.applied(value: result.value, revision: revision, replayed: result.replayed)))
                case .reject(let reject)?:
                    settleOperation(reject.idempotencyKey,
                                    .success(.rejected(code: reject.code, message: reject.message,
                                                       retryable: reject.retryable, replayed: reject.replayed)))
                case .error(let error)?:
                    guard let id = error.id else { continue }
                    settleRead(id, .failure(MobileLinkClientError.refused(code: error.code, message: error.message,
                                                                          retryable: error.retryable)))
                default:
                    continue
                }
            case .binary, .gap:
                continue
            case .closed:
                if rpc?.generation == generation { rpc = nil }
                failReads()
                return
            }
        }
    }

    func settleRead(_ id: Int, _ result: Result<JSONValue, any Error>) {
        pendingReads.removeValue(forKey: id)?.resume(with: result)
    }

    func failReads() {
        let pending = pendingReads
        pendingReads.removeAll()
        for continuation in pending.values { continuation.resume(throwing: MobileLinkClientError.linkLost) }
        let operations = pendingOperations
        pendingOperations.removeAll()
        for continuation in operations.values { continuation.resume(throwing: MobileLinkClientError.linkLost) }
    }

    func settleOperation(_ key: String, _ result: Result<MobileLinkOperationResult, any Error>) {
        pendingOperations.removeValue(forKey: key)?.resume(with: result)
    }
}
