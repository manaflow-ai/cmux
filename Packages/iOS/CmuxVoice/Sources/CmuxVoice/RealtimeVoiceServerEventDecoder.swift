import Foundation

/// Strict decoder for the small Realtime server-event subset cmux consumes.
struct RealtimeVoiceServerEventDecoder: Sendable {
    func decode(_ data: Data) -> RealtimeVoiceServerEvent? {
        guard data.count <= 2 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "session.created", "session.updated":
            return .sessionReady
        case "input_audio_buffer.committed":
            guard let itemID = object["item_id"] as? String else { return nil }
            return .inputCommitted(itemID: itemID)
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = object["item_id"] as? String,
                  let delta = object["delta"] as? String else { return nil }
            return .inputTranscriptDelta(itemID: itemID, delta: delta)
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = object["item_id"] as? String,
                  let transcript = object["transcript"] as? String else { return nil }
            return .inputTranscriptCompleted(itemID: itemID, transcript: transcript)
        case "conversation.item.input_audio_transcription.failed":
            guard let itemID = object["item_id"] as? String else { return nil }
            return .inputTranscriptFailed(itemID: itemID)
        case "response.output_audio.delta":
            guard let itemID = object["item_id"] as? String,
                  let delta = object["delta"] as? String,
                  let audio = Data(base64Encoded: delta),
                  audio.count <= 512 * 1_024 else { return nil }
            return .outputAudioDelta(itemID: itemID, data: audio)
        case "response.output_audio.done":
            return .outputAudioDone
        case "response.output_audio_transcript.delta":
            guard let delta = object["delta"] as? String else { return nil }
            return .outputTranscriptDelta(delta)
        case "response.output_audio_transcript.done":
            guard let transcript = object["transcript"] as? String else { return nil }
            return .outputTranscriptCompleted(transcript)
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "response.created":
            guard let response = object["response"] as? [String: Any],
                  let responseID = response["id"] as? String,
                  !responseID.isEmpty else {
                return nil
            }
            return .responseCreated(responseID: responseID)
        case "response.done":
            let response = object["response"] as? [String: Any]
            return .responseDone(
                responseID: response?["id"] as? String,
                calls: Self.functionCalls(from: object)
            )
        case "error", "invalid_request_error":
            return .serviceError
        default:
            return .ignored
        }
    }

    private static func functionCalls(from object: [String: Any]) -> [RealtimeVoiceFunctionCall] {
        guard let response = object["response"] as? [String: Any],
              let output = response["output"] as? [[String: Any]] else {
            return []
        }
        return output.compactMap { item in
            guard item["type"] as? String == "function_call",
                  let callID = item["call_id"] as? String,
                  let name = item["name"] as? String,
                  let arguments = item["arguments"] as? String,
                  !callID.isEmpty,
                  !name.isEmpty,
                  arguments.utf8.count <= 32 * 1_024 else {
                return nil
            }
            return RealtimeVoiceFunctionCall(
                callID: callID,
                name: name,
                arguments: arguments
            )
        }
    }
}
