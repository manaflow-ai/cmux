import Foundation

extension MobileCoreRPCSession {
    /// Routes one decoded control-stream frame: server-pushed events fan out to
    /// topic listeners, responses settle their pending request continuations.
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
              pending[id] != nil || pipelinedPending[id] != nil else { return }
        if (envelope["ok"] as? Bool) == true {
            let result = envelope["result"] ?? [:]
            if let data = try? JSONSerialization.data(withJSONObject: result) {
                settlePendingRequest(
                    requestID: id,
                    settlement: .response(.success(data))
                )
            } else {
                settlePendingRequest(
                    requestID: id,
                    settlement: .response(.failure(.invalidResponse))
                )
            }
            return
        }
        let errorPayload = envelope["error"] as? [String: Any]
        let message = (errorPayload?["message"] as? String) ?? "RPC error"
        let code = errorPayload?["code"] as? String
        switch code {
        case "unauthorized":
            settlePendingRequest(
                requestID: id,
                settlement: .response(.failure(.authorizationFailed(message)))
            )
        case "account_mismatch":
            settlePendingRequest(
                requestID: id,
                settlement: .response(.failure(.accountMismatch(message)))
            )
        default:
            settlePendingRequest(
                requestID: id,
                settlement: .response(.failure(.rpcError(code, message)))
            )
        }
    }
}
