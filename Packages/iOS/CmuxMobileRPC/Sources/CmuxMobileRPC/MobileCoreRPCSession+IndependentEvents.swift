internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    /// Negotiates the optional event lane at most once for a subscription ID.
    /// Re-assertions are control-channel liveness probes, so they only reuse an
    /// already-active reader and never spend their deadline reopening a sidecar.
    func prepareIndependentServerEvents(
        forSubscriptionStreamID streamID: String,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        let normalizedStreamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedStreamID.isEmpty,
           independentEventSubscriptionStreamIDs.contains(normalizedStreamID) {
            return independentEventReader != nil
        }
        let prepared = await prepareIndependentServerEvents(
            timeoutNanoseconds: timeoutNanoseconds
        )
        if !normalizedStreamID.isEmpty {
            independentEventSubscriptionStreamIDs.insert(normalizedStreamID)
        }
        return prepared
    }

    /// Prepares one independently framed server-event reader when the active
    /// route supports it. Concurrent callers coalesce onto the same provider.
    func prepareIndependentServerEvents(
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        if independentEventReader != nil { return true }
        guard !isTearingDown, let makeIndependentEventByteStream else { return false }

        let preparation: IndependentEventPreparation
        if let current = independentEventPreparation {
            preparation = current
        } else {
            let task = Task { try await makeIndependentEventByteStream() }
            preparation = IndependentEventPreparation(id: UUID(), task: task)
            independentEventPreparation = preparation
        }

        do {
            let stream: CmxIndependentEventByteStream
            if let timeoutNanoseconds {
                stream = try await taskTimeout.value(
                    preparation.task,
                    timeoutNanoseconds: timeoutNanoseconds
                )
            } else {
                stream = try await preparation.task.value
            }
            guard independentEventPreparation?.id == preparation.id else {
                return independentEventReader != nil
            }
            independentEventPreparation = nil
            guard !isTearingDown else { return false }
            if independentEventReader != nil { return true }

            let readerID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.readIndependentEventLoop(stream: stream, id: readerID)
            }
            independentEventReader = IndependentEventReader(id: readerID, task: task)
            return true
        } catch MobileShellConnectionError.requestTimedOut {
            return independentEventReader != nil
        } catch is CancellationError {
            return independentEventReader != nil
        } catch {
            if independentEventPreparation?.id == preparation.id {
                independentEventPreparation = nil
            }
            return independentEventReader != nil
        }
    }

    /// A malformed or closed optional event stream leaves control RPCs alive.
    private func readIndependentEventLoop(
        stream: CmxIndependentEventByteStream,
        id: UUID
    ) async {
        defer {
            if independentEventReader?.id == id {
                independentEventReader = nil
            }
        }

        var buffer = Data()
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                guard !chunk.isEmpty else { continue }
                guard chunk.count <= Self.maximumReceiveBufferByteCount - buffer.count else {
                    throw MobileSyncFrameCodecError.frameTooLarge(buffer.count + chunk.count)
                }
                buffer.append(chunk)
                let frames = try MobileSyncFrameCodec.decodeFrames(
                    from: &buffer,
                    maximumDecodedFrameCount: Self.maximumDecodedFrameCountPerRead
                )
                for frame in frames { dispatch(frame: frame) }
            }
        } catch {
            // The host falls back to control delivery after optional-lane failure.
        }
    }

    func dispatch(frame: Data) {
        let parsed = try? JSONSerialization.jsonObject(with: frame) as? [String: Any]
        guard let envelope = parsed else { return }
        if (envelope["kind"] as? String) == "event" {
            guard let topic = envelope["topic"] as? String else { return }
            let payloadData: Data?
            if let payload = envelope["payload"] {
                payloadData = try? JSONSerialization.data(withJSONObject: payload)
            } else {
                payloadData = nil
            }
            let event = MobileEventEnvelope(
                topic: topic,
                payloadJSON: payloadData,
                streamID: envelope["stream_id"] as? String
            )
            for (_, listener) in listeners where listener.topics.contains(topic) {
                listener.continuation.yield(event)
            }
            return
        }
        guard let id = envelope["id"] as? String,
              let cont = pending.removeValue(forKey: id) else { return }
        requestTimeoutTasks.removeValue(forKey: id)?.cancel()
        if (envelope["ok"] as? Bool) == true {
            let result = envelope["result"] ?? [:]
            if let data = try? JSONSerialization.data(withJSONObject: result) {
                cont.resume(returning: .response(.success(data)))
            } else {
                cont.resume(returning: .response(.failure(.invalidResponse)))
            }
            return
        }
        let errorPayload = envelope["error"] as? [String: Any]
        let message = (errorPayload?["message"] as? String) ?? "RPC error"
        let code = errorPayload?["code"] as? String
        switch code {
        case "unauthorized":
            cont.resume(returning: .response(.failure(.authorizationFailed(message))))
        case "account_mismatch":
            cont.resume(returning: .response(.failure(.accountMismatch(message))))
        default:
            cont.resume(returning: .response(.failure(.rpcError(code, message))))
        }
    }
}
