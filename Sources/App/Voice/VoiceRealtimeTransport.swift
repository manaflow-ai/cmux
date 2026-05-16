import Foundation
import AVFoundation

// MARK: - Client events (outbound)

enum RealtimeClientEvent: Encodable {
    case sessionUpdate(model: String, instructions: String, tools: [VoiceToolDefinition])
    case audioAppend(Data)
    case functionCallOutput(callId: String, output: String)
    case responseCreate

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionUpdate(_, let instructions, let tools):
            try container.encode("session.update", forKey: .type)
            var sessionContainer = container.nestedContainer(keyedBy: SessionKeys.self, forKey: .session)
            try sessionContainer.encode("realtime", forKey: .sessionType)
            try sessionContainer.encode(instructions, forKey: .instructions)
            try sessionContainer.encode(tools, forKey: .tools)
            try sessionContainer.encode("auto", forKey: .toolChoice)
        case .audioAppend(let data):
            try container.encode("input_audio_buffer.append", forKey: .type)
            try container.encode(data.base64EncodedString(), forKey: .audio)
        case .functionCallOutput(let callId, let output):
            try container.encode("conversation.item.create", forKey: .type)
            var itemContainer = container.nestedContainer(keyedBy: ItemKeys.self, forKey: .item)
            try itemContainer.encode("function_call_output", forKey: .type)
            try itemContainer.encode(callId, forKey: .callId)
            try itemContainer.encode(output, forKey: .output)
        case .responseCreate:
            try container.encode("response.create", forKey: .type)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, session, audio, item
    }
    enum SessionKeys: String, CodingKey {
        case sessionType = "type", instructions, tools, toolChoice = "tool_choice"
    }
    enum ItemKeys: String, CodingKey {
        case type, callId = "call_id", output
    }
}

// MARK: - Server events (inbound)

enum RealtimeServerEvent: Decodable {
    case sessionCreated
    case serverError(String)
    case functionCallDone(VoiceToolCall)
    case transcript(String)
    case textDelta(String)
    case responseDone
    case speechStarted
    case other(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type_ = try container.decode(String.self, forKey: .type)
        switch type_ {
        case "session.created":
            self = .sessionCreated
        case "error":
            let root = try decoder.container(keyedBy: ErrorKeys.self)
            let errObj = try? root.decode(ErrorBody.self, forKey: .error)
            let msg = errObj?.message ?? errObj?.type ?? "Unknown server error"
            self = .serverError(msg)
        case "response.function_call_arguments.done":
            let call = try VoiceToolCall(from: decoder)
            self = .functionCallDone(call)
        case "conversation.item.input_audio_transcription.completed":
            let root = try decoder.container(keyedBy: TranscriptKeys.self)
            let text = (try? root.decode(String.self, forKey: .transcript)) ?? ""
            self = .transcript(text)
        case "response.text.delta", "response.output_text.delta", "response.output_audio_transcript.delta":
            let root = try decoder.container(keyedBy: DeltaKeys.self)
            let delta = (try? root.decode(String.self, forKey: .delta)) ?? ""
            self = .textDelta(delta)
        case "response.done":
            self = .responseDone
        case "input_audio_buffer.speech_started":
            self = .speechStarted
        default:
            self = .other(type_)
        }
    }

    enum TypeKey: String, CodingKey { case type }
    enum ErrorKeys: String, CodingKey { case error }
    enum TranscriptKeys: String, CodingKey { case transcript }
    enum DeltaKeys: String, CodingKey { case delta }

    private struct ErrorBody: Decodable {
        let type: String?
        let message: String?
    }
}

// MARK: - Transport

@MainActor
final class VoiceRealtimeTransport: NSObject {
    enum ConnectionState { case disconnected, connecting, connected, failed(Error) }

    private let endpoint = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview")!

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    var onToolCall: ((VoiceToolCall) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?
    var onSessionCreated: (() -> Void)?
    var onServerError: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onTextDelta: ((String) -> Void)?
    var onResponseDone: (() -> Void)?
    var onSpeechStarted: (() -> Void)?

    func connect(apiKey: String) {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
        urlSession = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        onStateChange?(.connecting)
        task.resume()
        receiveLoop()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession = nil
        onStateChange?(.disconnected)
    }

    func send(_ event: RealtimeClientEvent) {
        guard let task = webSocketTask else { return }
        guard let data = try? JSONEncoder().encode(event),
              let text = String(data: data, encoding: .utf8) else { return }
        #if DEBUG
        switch event {
        case .sessionUpdate: cmuxDebugLog("voice.ws.send sessionUpdate \(text.prefix(400))")
        case .functionCallOutput(let callId, let output): cmuxDebugLog("voice.ws.send toolResult callId=\(callId) output=\(output.prefix(120))")
        case .responseCreate: cmuxDebugLog("voice.ws.send responseCreate")
        case .audioAppend: break
        }
        #endif
        task.send(.string(text)) { _ in }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure(let error):
                    #if DEBUG
                    cmuxDebugLog("voice.ws.error \(error.localizedDescription)")
                    #endif
                    self.onStateChange?(.failed(error))
                case .success(let message):
                    self.onStateChange?(.connected)
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let event = try? JSONDecoder().decode(RealtimeServerEvent.self, from: data) {
                        #if DEBUG
                        switch event {
                        case .other(let t): cmuxDebugLog("voice.ws.other type=\(t)")
                        case .textDelta(let d) where !d.isEmpty: cmuxDebugLog("voice.ws.aiSpeech '\(d.prefix(80))'")
                        case .transcript(let t): cmuxDebugLog("voice.ws.transcript '\(t.prefix(80))'")
                        case .serverError(let msg): cmuxDebugLog("voice.ws.serverError \(msg)")
                        case .functionCallDone(let call): cmuxDebugLog("voice.ws.toolCall name=\(call.name) args=\(call.arguments.prefix(120))")
                        case .sessionCreated: cmuxDebugLog("voice.ws.sessionCreated")
                        case .speechStarted: cmuxDebugLog("voice.ws.speechStarted")
                        case .responseDone: cmuxDebugLog("voice.ws.responseDone")
                        default: break
                        }
                        #endif
                        switch event {
                        case .sessionCreated: self.onSessionCreated?()
                        case .serverError(let msg): self.onServerError?(msg)
                        case .functionCallDone(let call): self.onToolCall?(call)
                        case .transcript(let t): self.onTranscript?(t)
                        case .textDelta(let d): self.onTextDelta?(d)
                        case .responseDone: self.onResponseDone?()
                        case .speechStarted: self.onSpeechStarted?()
                        case .other: break
                        }
                    } else if case .string(let text) = message {
                        #if DEBUG
                        cmuxDebugLog("voice.ws.undecodable \(text.prefix(120))")
                        #endif
                    }
                    self.receiveLoop()
                }
            }
        }
    }
}
