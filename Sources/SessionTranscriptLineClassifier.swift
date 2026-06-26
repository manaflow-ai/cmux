import Foundation

/// Byte-level classifier for a single raw JSONL transcript line. Decides whether
/// a line is worth JSON-parsing for the preview and, when needed, infers its
/// `SessionTranscriptRole` purely from byte needles, without decoding the line.
/// A real value type whose stored state is the per-agent needle tables, built
/// once in `init` and reused, so the hot per-line matching never reallocates the
/// needle arrays. Pure matching only: no localization, no I/O.
struct SessionTranscriptLineClassifier {
    private let claudeUserNeedles: [Data]
    private let codexResponseItemNeedles: [Data]
    private let codexPreviewNeedles: [Data]
    private let genericRoleNeedles: [Data]
    private let grokAssistantRoleNeedles: [Data]
    private let grokUserRoleNeedles: [Data]
    private let grokSystemRoleNeedles: [Data]
    private let grokToolRoleNeedles: [Data]
    private let grokRoleNeedles: [Data]

    // Wrapping `Data(string.utf8)` in a helper keeps large needle array literals
    // cheap to type-check. The Xcode 27 / Swift 6.4 expression solver otherwise
    // times out on the bigger literals below ("unable to type-check this
    // expression in reasonable time"), which Xcode 26 tolerated.
    private static func needle(_ string: String) -> Data { Data(string.utf8) }

    init() {
        let claudeUserNeedles = [
            Data(#""type":"user""#.utf8),
            Data(#""type": "user""#.utf8),
            Data(#""type":"assistant""#.utf8),
            Data(#""type": "assistant""#.utf8)
        ]
        let codexResponseItemNeedles = [
            Data(#""type":"response_item""#.utf8),
            Data(#""type": "response_item""#.utf8)
        ]
        let codexPreviewNeedles = [
            Data(#""role":"user""#.utf8),
            Data(#""role": "user""#.utf8),
            Data(#""role":"assistant""#.utf8),
            Data(#""role": "assistant""#.utf8),
            Data(#""type":"function_call""#.utf8),
            Data(#""type": "function_call""#.utf8),
            Data(#""type":"function_call_output""#.utf8),
            Data(#""type": "function_call_output""#.utf8)
        ]
        let genericRoleNeedles = [
            Data(#""role":"#.utf8),
            Data(#""role": "#.utf8)
        ]
        let grokAssistantRoleNeedles = [
            Data(#""role":"assistant""#.utf8),
            Data(#""role": "assistant""#.utf8),
            Data(#""type":"assistant""#.utf8),
            Data(#""type": "assistant""#.utf8)
        ]
        let grokUserRoleNeedles = [
            Data(#""role":"user""#.utf8),
            Data(#""role": "user""#.utf8),
            Data(#""type":"user""#.utf8),
            Data(#""type": "user""#.utf8)
        ]
        let grokSystemRoleNeedles = [
            Data(#""role":"system""#.utf8),
            Data(#""role": "system""#.utf8),
            Data(#""role":"developer""#.utf8),
            Data(#""role": "developer""#.utf8),
            Data(#""type":"system""#.utf8),
            Data(#""type": "system""#.utf8),
            Data(#""type":"developer""#.utf8),
            Data(#""type": "developer""#.utf8)
        ]
        let grokToolRoleNeedles = [
            Self.needle(#""role":"tool""#),
            Self.needle(#""role": "tool""#),
            Self.needle(#""role":"tool_use""#),
            Self.needle(#""role": "tool_use""#),
            Self.needle(#""role":"tool_result""#),
            Self.needle(#""role": "tool_result""#),
            Self.needle(#""role":"function_call""#),
            Self.needle(#""role": "function_call""#),
            Self.needle(#""role":"function_call_output""#),
            Self.needle(#""role": "function_call_output""#),
            Self.needle(#""type":"tool""#),
            Self.needle(#""type": "tool""#),
            Self.needle(#""type":"tool_use""#),
            Self.needle(#""type": "tool_use""#),
            Self.needle(#""type":"tool_result""#),
            Self.needle(#""type": "tool_result""#),
            Self.needle(#""type":"function_call""#),
            Self.needle(#""type": "function_call""#),
            Self.needle(#""type":"function_call_output""#),
            Self.needle(#""type": "function_call_output""#)
        ]
        let grokRoleNeedles = [
            Self.needle(#""role":"#),
            Self.needle(#""role": "#)
        ]
            + grokAssistantRoleNeedles
            + grokUserRoleNeedles
            + grokSystemRoleNeedles
            + grokToolRoleNeedles

        self.claudeUserNeedles = claudeUserNeedles
        self.codexResponseItemNeedles = codexResponseItemNeedles
        self.codexPreviewNeedles = codexPreviewNeedles
        self.genericRoleNeedles = genericRoleNeedles
        self.grokAssistantRoleNeedles = grokAssistantRoleNeedles
        self.grokUserRoleNeedles = grokUserRoleNeedles
        self.grokSystemRoleNeedles = grokSystemRoleNeedles
        self.grokToolRoleNeedles = grokToolRoleNeedles
        self.grokRoleNeedles = grokRoleNeedles
    }

    func shouldParseRawLine(
        _ data: Data,
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool
    ) -> Bool {
        if usesGrokTranscriptLayout {
            return containsAny(data, needles: grokRoleNeedles)
        }
        switch agent {
        case .claude:
            return containsAny(data, needles: claudeUserNeedles)
        case .codex:
            return containsAny(data, needles: codexResponseItemNeedles)
                && containsAny(data, needles: codexPreviewNeedles)
        case .grok:
            return containsAny(data, needles: grokRoleNeedles)
        case .opencode, .rovodev:
            return containsAny(data, needles: genericRoleNeedles)
        case .registered:
            return true
        case .hermesAgent:
            return false
        }
    }

    func inferredRole(
        from data: Data,
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool
    ) -> SessionTranscriptRole? {
        if usesGrokTranscriptLayout {
            return inferredGrokRole(from: data)
        }
        switch agent {
        case .claude:
            if containsAny(data, needles: [Data(#""type":"assistant""#.utf8), Data(#""type": "assistant""#.utf8)]) {
                return .assistant
            }
            if containsAny(data, needles: [Data(#""type":"user""#.utf8), Data(#""type": "user""#.utf8)]) {
                return .user
            }
        case .codex, .opencode, .rovodev, .registered:
            if containsAny(data, needles: [Data(#""role":"assistant""#.utf8), Data(#""role": "assistant""#.utf8)]) {
                return .assistant
            }
            if containsAny(data, needles: [Data(#""role":"user""#.utf8), Data(#""role": "user""#.utf8)]) {
                return .user
            }
            if containsAny(data, needles: [Data(#""type":"function_call""#.utf8), Data(#""type": "function_call""#.utf8)]) {
                return .tool
            }
        case .grok:
            return inferredGrokRole(from: data)
        case .hermesAgent:
            return nil
        }
        return nil
    }

    private func inferredGrokRole(from data: Data) -> SessionTranscriptRole? {
        if containsAny(data, needles: grokAssistantRoleNeedles) {
            return .assistant
        }
        if containsAny(data, needles: grokUserRoleNeedles) {
            return .user
        }
        if containsAny(data, needles: grokSystemRoleNeedles) {
            return .system
        }
        if containsAny(data, needles: grokToolRoleNeedles) {
            return .tool
        }
        return nil
    }

    private func containsAny(_ data: Data, needles: [Data]) -> Bool {
        needles.contains { data.range(of: $0) != nil }
    }
}
