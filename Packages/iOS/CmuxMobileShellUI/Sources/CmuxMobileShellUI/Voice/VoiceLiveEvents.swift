import Foundation

/// A function tool exposed to the GPT-Live Responses backend. Parameters are
/// carried as a serialized JSON Schema string so the value stays `Sendable`;
/// the encoder inflates it at send time.
public struct VoiceLiveTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// Session configuration sent in `session.start`.
public struct VoiceLiveSessionConfig: Sendable {
    /// Who does the thinking behind the voice.
    ///
    /// - `client`: this app is the backend (terminal voice mode: the coding
    ///   agent in the terminal is the brain; the app relays both directions).
    /// - `responses`: OpenAI runs a Responses model with our function tools
    ///   (orchestrator mode: the app executes tool calls against the shell
    ///   store and returns outputs).
    public enum Delegation: Sendable {
        case client
        case responses(model: String, instructions: String, tools: [VoiceLiveTool])
    }

    public var model: String
    public var voice: String
    public var instructions: String
    public var delegation: Delegation

    public init(model: String, voice: String, instructions: String, delegation: Delegation) {
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.delegation = delegation
    }
}

/// Client → server events for one GPT-Live WebSocket session
/// (`wss://api.openai.com/v1/live/sessions`). Shapes follow the Live API
/// WebSocket guide; unknown-field tolerance on the server side lets us keep
/// these minimal.
public enum VoiceLiveClientEvent: Sendable {
    case sessionStart(VoiceLiveSessionConfig)
    /// Raw mono PCM16 @ 24 kHz, base64-encoded by the encoder.
    case inputAudioAppend(Data)
    /// Text the voice should speak (paraphrased), optionally tied to a
    /// delegation. Capped upstream at 500 tokens per append; callers chunk.
    case commentaryAppend(text: String, delegationID: String?)
    /// Facts/progress for the voice model's context, not spoken on append.
    case thinkingAppend(text: String, delegationID: String?)
    /// System-level steering of the live conversation.
    case instructionsAppend(text: String)
    /// A completed function-tool result (Responses delegation only)...
    case functionCallOutput(callID: String, output: String)
    /// ...followed by this to resume the delegated response.
    case responseCreate
    case inputAudioMute
    case inputAudioUnmute
    case sessionClose

    /// Serialize with a caller-supplied event id (used to correlate error
    /// events back to the command that caused them).
    public func jsonData(eventID: String) throws -> Data {
        var payload: [String: Any]
        switch self {
        case .sessionStart(let config):
            payload = [
                "type": "session.start",
                "session": Self.sessionDictionary(config),
            ]
        case .inputAudioAppend(let audio):
            payload = [
                "type": "session.input_audio.append",
                "audio": audio.base64EncodedString(),
            ]
        case .commentaryAppend(let text, let delegationID):
            payload = [
                "type": "session.commentary.append",
                "content": text,
                "delegation_id": delegationID as Any? ?? NSNull(),
            ]
        case .thinkingAppend(let text, let delegationID):
            payload = [
                "type": "session.thinking.append",
                "content": text,
                "delegation_id": delegationID as Any? ?? NSNull(),
            ]
        case .instructionsAppend(let text):
            payload = [
                "type": "session.instructions.append",
                "content": text,
                "delegation_id": NSNull(),
            ]
        case .functionCallOutput(let callID, let output):
            payload = [
                "type": "response.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output,
                ],
            ]
        case .responseCreate:
            payload = ["type": "response.create"]
        case .inputAudioMute:
            payload = ["type": "session.input_audio.mute"]
        case .inputAudioUnmute:
            payload = ["type": "session.input_audio.unmute"]
        case .sessionClose:
            payload = ["type": "session.close"]
        }
        payload["event_id"] = eventID
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func sessionDictionary(_ config: VoiceLiveSessionConfig) -> [String: Any] {
        var session: [String: Any] = [
            "model": config.model,
            "instructions": config.instructions,
            "audio": [
                "format": [
                    "type": "audio/pcm",
                    "rate": 24_000,
                ],
                "output": ["voice": config.voice],
            ],
        ]
        switch config.delegation {
        case .client:
            session["delegation"] = ["type": "client"]
        case .responses(let model, let instructions, let tools):
            session["delegation"] = [
                "type": "responses",
                "responses": [
                    "model": model,
                    "instructions": instructions,
                    "tools": tools.map { tool -> [String: Any] in
                        let parameters = (try? JSONSerialization.jsonObject(
                            with: Data(tool.parametersJSON.utf8)
                        )) as? [String: Any] ?? [:]
                        return [
                            "type": "function",
                            "name": tool.name,
                            "description": tool.description,
                            "parameters": parameters,
                        ]
                    },
                    "tool_choice": "auto",
                    // Serial tool calls: the app must return every pending
                    // call's output before response.create, and the
                    // destructive-approval gate can hold one call open for
                    // arbitrarily long. One-at-a-time keeps that sound.
                    "parallel_tool_calls": false,
                ] as [String: Any],
            ]
        }
        return session
    }
}

/// Server → client events this feature reacts to. Anything unrecognized maps
/// to ``other(type:)`` so protocol growth never breaks the session loop.
public enum VoiceLiveServerEvent: Sendable, Equatable {
    case started(sessionID: String)
    /// Decoded speech audio: mono PCM16 @ 24 kHz.
    case outputAudioDelta(Data)
    case inputTranscriptDelta(String)
    case outputTranscriptDelta(String)
    /// The voice model handed work to the backend. In client mode the app is
    /// that backend; the event carries no task text — intent comes from the
    /// accumulated input transcript.
    case delegationCreated(id: String, target: String)
    /// A completed function call from the Responses backend (extracted from
    /// the `response.event` envelope's `response.output_item.done`).
    case functionCall(callID: String, name: String, argumentsJSON: String, delegationID: String?)
    case usageUpdated(seconds: Int)
    case errorEvent(code: String?, message: String?)
    case closed(reason: String?)
    case other(type: String)

    /// Parse one WebSocket text frame. Returns `nil` only for frames that are
    /// not JSON objects with a `type`.
    public static func parse(_ data: Data) -> VoiceLiveServerEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let event = object as? [String: Any],
              let type = event["type"] as? String
        else { return nil }
        switch type {
        case "session.started":
            let session = event["session"] as? [String: Any]
            return .started(sessionID: session?["id"] as? String ?? "")
        case "session.output_audio.delta":
            guard let base64 = event["delta"] as? String,
                  let audio = Data(base64Encoded: base64)
            else { return .other(type: type) }
            return .outputAudioDelta(audio)
        case "session.input_transcript.delta":
            return .inputTranscriptDelta(event["delta"] as? String ?? "")
        case "session.output_transcript.delta":
            return .outputTranscriptDelta(event["delta"] as? String ?? "")
        case "session.delegation.created":
            let delegation = event["delegation"] as? [String: Any]
            return .delegationCreated(
                id: delegation?["id"] as? String ?? "",
                target: delegation?["target"] as? String ?? ""
            )
        case "response.event":
            return parseResponseEnvelope(event)
        case "session.usage.updated":
            let usage = event["usage"] as? [String: Any]
            return .usageUpdated(seconds: usage?["seconds"] as? Int ?? 0)
        case "error":
            let error = event["error"] as? [String: Any]
            return .errorEvent(
                code: (error?["code"] ?? error?["type"]) as? String,
                message: (error?["message"] ?? event["message"]) as? String
            )
        case "session.closed":
            return .closed(reason: event["reason"] as? String)
        default:
            return .other(type: type)
        }
    }

    /// Function calls arrive as completed items inside forwarded Responses
    /// events. Only `response.output_item.done` with a `function_call` item
    /// reliably identifies a call (an arguments-done event alone does not).
    private static func parseResponseEnvelope(
        _ envelope: [String: Any]
    ) -> VoiceLiveServerEvent {
        let delegationID = envelope["delegation_id"] as? String
        guard let nested = envelope["event"] as? [String: Any],
              let nestedType = nested["type"] as? String
        else { return .other(type: "response.event") }
        guard nestedType == "response.output_item.done",
              let item = nested["item"] as? [String: Any],
              item["type"] as? String == "function_call",
              let callID = item["call_id"] as? String,
              let name = item["name"] as? String
        else { return .other(type: "response.event:\(nestedType)") }
        return .functionCall(
            callID: callID,
            name: name,
            argumentsJSON: item["arguments"] as? String ?? "{}",
            delegationID: delegationID
        )
    }
}
