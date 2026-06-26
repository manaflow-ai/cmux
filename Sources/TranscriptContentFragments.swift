import Foundation

/// Extracts flat text fragments from one agent-transcript record's decoded JSON
/// content (the `Any?` produced by `JSONSerialization`). A value type wrapping
/// the decoded content so a call site reads as
/// `TranscriptContentFragments(value).fragments`; the recursive walk stays on
/// private `static` helpers so the transform is a pure function of its input
/// with no retained state, and the depth-first traversal, key precedence, and
/// pretty-printed JSON rendering are byte-identical to the legacy parser.
struct TranscriptContentFragments {
    /// Decoded JSON content: a `String`, `[Any]`, `[String: Any]`, or `nil`.
    let content: Any?

    init(_ content: Any?) {
        self.content = content
    }

    /// Depth-first, flattened text fragments extracted from `content`.
    var fragments: [String] {
        Self.textFragments(from: content)
    }

    private static func textFragments(from value: Any?) -> [String] {
        guard let value else { return [] }
        if let string = value as? String {
            return [string]
        }
        if let array = value as? [Any] {
            return array.flatMap { textFragments(from: $0) }
        }
        guard let object = value as? [String: Any] else {
            return []
        }

        let type = object["type"] as? String
        switch type {
        case "text", "input_text", "output_text":
            if let text = object["text"] as? String {
                return [text]
            }
        case "tool":
            return openCodeToolFragments(from: object)
        case "tool_use", "function_call":
            return toolCallFragments(from: object)
        case "tool_result", "function_call_output":
            let fragments = textFragments(from: object["content"] ?? object["output"] ?? object["result"])
            if !fragments.isEmpty {
                return fragments
            }
        case "patch":
            return openCodePatchFragments(from: object)
        case "file":
            return openCodeFileFragments(from: object)
        default:
            break
        }

        for key in ["text", "content", "output", "result", "message"] {
            let fragments = textFragments(from: object[key])
            if !fragments.isEmpty {
                return fragments
            }
        }
        return []
    }

    private static func openCodeToolFragments(from object: [String: Any]) -> [String] {
        var parts: [String] = []
        if let tool = object["tool"] as? String, !tool.isEmpty {
            parts.append(tool)
        }
        if let state = object["state"],
           let rendered = renderedJSON(state) {
            parts.append(rendered)
        }
        return parts
    }

    private static func openCodePatchFragments(from object: [String: Any]) -> [String] {
        if let files = object["files"] as? [String], !files.isEmpty {
            return files
        }
        if let hash = object["hash"] as? String, !hash.isEmpty {
            return [hash]
        }
        return []
    }

    private static func openCodeFileFragments(from object: [String: Any]) -> [String] {
        var parts: [String] = []
        if let filename = object["filename"] as? String, !filename.isEmpty {
            parts.append(filename)
        }
        if let mime = object["mime"] as? String, !mime.isEmpty {
            parts.append(mime)
        }
        return parts
    }

    private static func toolCallFragments(from object: [String: Any]) -> [String] {
        var parts: [String] = []
        if let name = object["name"] as? String, !name.isEmpty {
            parts.append(name)
        }
        if let input = object["input"] ?? object["arguments"],
           let rendered = renderedJSON(input) {
            parts.append(rendered)
        }
        return parts
    }

    private static func renderedJSON(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
