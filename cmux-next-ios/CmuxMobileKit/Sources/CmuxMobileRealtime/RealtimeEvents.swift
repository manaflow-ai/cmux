import Foundation

/// A function the voice model asked the app to run (an item of type
/// `function_call` in `response.done`).
public struct RealtimeFunctionCall: Sendable, Equatable {
    public var callID: String
    public var name: String
    /// The arguments as the model wrote them: a JSON object string.
    public var arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }

    /// The arguments decoded, or an empty object when they don't parse.
    public var argumentObject: [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

/// What `response.done` reports: how the response ended and the functions it called.
public struct RealtimeResponseSummary: Sendable, Equatable {
    /// `completed`, `cancelled`, `failed` or `incomplete`.
    public var status: String
    public var functionCalls: [RealtimeFunctionCall]
    /// The reason a failed response gives (`status_details.error.message`).
    public var failureMessage: String?
    /// `status_details.error.code`, e.g. `insufficient_quota`.
    public var failureCode: String?

    public init(status: String, functionCalls: [RealtimeFunctionCall] = [], failureMessage: String? = nil,
                failureCode: String? = nil) {
        self.status = status
        self.functionCalls = functionCalls
        self.failureMessage = failureMessage
        self.failureCode = failureCode
    }
}

/// An `error` event's details.
public struct RealtimeErrorInfo: Sendable, Equatable {
    public var type: String?
    public var code: String?
    public var message: String
    public var param: String?

    public init(type: String? = nil, code: String? = nil, message: String, param: String? = nil) {
        self.type = type
        self.code = code
        self.message = message
        self.param = param
    }
}

/// The server events a Chief call acts on, decoded from the `oai-events`
/// data channel (the Realtime API's GA event names). Everything else
/// decodes to ``other(_:)`` and is ignored.
public enum RealtimeServerEvent: Sendable, Equatable {
    case sessionCreated
    case sessionUpdated
    /// The user started talking (server VAD); the server cuts Chief off.
    case speechStarted(itemID: String?)
    case speechStopped(itemID: String?)
    case userTranscriptDelta(itemID: String, delta: String)
    case userTranscriptDone(itemID: String, transcript: String)
    case userTranscriptFailed(itemID: String)
    case responseCreated
    /// Chief's spoken words as they are generated (or text, for a text-only response).
    case assistantTranscriptDelta(itemID: String, delta: String)
    case assistantTranscriptDone(itemID: String, transcript: String)
    /// WebRTC: Chief's audio started, finished or was cut off in the phone's buffer.
    case outputAudioStarted
    case outputAudioStopped
    case outputAudioCleared
    case responseDone(RealtimeResponseSummary)
    case error(RealtimeErrorInfo)
    case other(String)

    /// Decodes one data channel message; nil when it is not a JSON event.
    public init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let itemID = object["item_id"] as? String
        switch type {
        case "session.created": self = .sessionCreated
        case "session.updated": self = .sessionUpdated
        case "input_audio_buffer.speech_started": self = .speechStarted(itemID: itemID)
        case "input_audio_buffer.speech_stopped": self = .speechStopped(itemID: itemID)
        case "conversation.item.input_audio_transcription.delta":
            self = .userTranscriptDelta(itemID: itemID ?? "", delta: object["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            self = .userTranscriptDone(itemID: itemID ?? "", transcript: object["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.failed":
            self = .userTranscriptFailed(itemID: itemID ?? "")
        case "response.created": self = .responseCreated
        case "response.output_audio_transcript.delta", "response.output_text.delta":
            self = .assistantTranscriptDelta(itemID: itemID ?? "", delta: object["delta"] as? String ?? "")
        case "response.output_audio_transcript.done":
            self = .assistantTranscriptDone(itemID: itemID ?? "", transcript: object["transcript"] as? String ?? "")
        case "response.output_text.done":
            self = .assistantTranscriptDone(itemID: itemID ?? "", transcript: object["text"] as? String ?? "")
        case "output_audio_buffer.started": self = .outputAudioStarted
        case "output_audio_buffer.stopped": self = .outputAudioStopped
        case "output_audio_buffer.cleared": self = .outputAudioCleared
        case "response.done":
            self = .responseDone(Self.summary(object["response"] as? [String: Any] ?? [:]))
        case "error":
            let error = object["error"] as? [String: Any] ?? [:]
            self = .error(RealtimeErrorInfo(type: error["type"] as? String, code: error["code"] as? String,
                                            message: error["message"] as? String ?? "", param: error["param"] as? String))
        default: self = .other(type)
        }
    }

    private static func summary(_ response: [String: Any]) -> RealtimeResponseSummary {
        let output = response["output"] as? [[String: Any]] ?? []
        let calls = output.compactMap { item -> RealtimeFunctionCall? in
            guard item["type"] as? String == "function_call",
                  let callID = item["call_id"] as? String, let name = item["name"] as? String else { return nil }
            return RealtimeFunctionCall(callID: callID, name: name, arguments: item["arguments"] as? String ?? "{}")
        }
        let details = response["status_details"] as? [String: Any]
        let error = details?["error"] as? [String: Any]
        return RealtimeResponseSummary(status: response["status"] as? String ?? "completed", functionCalls: calls,
                                       failureMessage: error?["message"] as? String, failureCode: error?["code"] as? String)
    }
}

/// The client events a Chief call sends on the `oai-events` data channel.
public enum RealtimeClientEvent: Sendable, Equatable {
    /// A typed message from the user, as a user turn.
    case userText(String)
    /// Context for the voice model that the user didn't say (a new Chief
    /// message, a tool's progress), as a system message.
    case systemNote(String)
    case responseCreate
    /// Barge-in by tap: stop the response and drop Chief's unplayed audio.
    case responseCancel
    case outputAudioClear
    case functionOutput(callID: String, output: String)
    /// Switches input transcription to another model (the first was refused).
    case transcriptionModel(String)

    /// The event as JSON for the data channel.
    public var data: Data {
        let object: [String: Any]
        switch self {
        case let .userText(text):
            object = ["type": "conversation.item.create",
                      "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]
        case let .systemNote(text):
            object = ["type": "conversation.item.create",
                      "item": ["type": "message", "role": "system", "content": [["type": "input_text", "text": text]]]]
        case .responseCreate:
            object = ["type": "response.create"]
        case .responseCancel:
            object = ["type": "response.cancel"]
        case .outputAudioClear:
            object = ["type": "output_audio_buffer.clear"]
        case let .functionOutput(callID, output):
            object = ["type": "conversation.item.create",
                      "item": ["type": "function_call_output", "call_id": callID, "output": output]]
        case let .transcriptionModel(model):
            object = ["type": "session.update",
                      "session": ["type": "realtime", "audio": ["input": ["transcription": ["model": model]]]]]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
