import Foundation

/// Complete function call emitted inside a Realtime `response.done` event.
struct RealtimeVoiceFunctionCall: Equatable, Sendable {
    let callID: String
    let name: String
    let arguments: String

    func decodedToolCall() -> RealtimeVoiceToolCall? {
        switch name {
        case "list_terminals":
            return .listTerminals
        case "send_latest_utterance":
            guard let data = arguments.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawTargetIDs = object["target_ids"] as? [String] else {
                return nil
            }
            let targetIDs = rawTargetIDs.reduce(into: [String]()) { result, rawValue in
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !result.contains(value), result.count < 32 else { return }
                result.append(value)
            }
            guard !targetIDs.isEmpty else { return nil }
            return .sendLatestUtterance(targetIDs: targetIDs)
        default:
            return nil
        }
    }
}
