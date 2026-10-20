import Foundation

extension WorkstreamQuestionPrompt {
    /// Parses Claude-style nested question input and the legacy flat question shape.
    ///
    /// - Parameter toolInputJSON: The serialized tool input, if present.
    /// - Returns: Parsed prompts, or an empty array when the input is absent or invalid.
    public static func parse(toolInputJSON: String?) -> [WorkstreamQuestionPrompt] {
        guard let toolInputJSON,
              let data = toolInputJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        if let questions = root["questions"] as? [[String: Any]] {
            return questions.enumerated().map { index, question in
                makeParsedQuestion(from: question, fallbackId: "q\(index)")
            }
        }
        return [makeParsedQuestion(from: root, fallbackId: "q0")]
    }

    private static func makeParsedQuestion(
        from dictionary: [String: Any],
        fallbackId: String
    ) -> WorkstreamQuestionPrompt {
        let header = (dictionary["header"] as? String) ?? (dictionary["title"] as? String)
        let prompt = (dictionary["question"] as? String)
            ?? (dictionary["prompt"] as? String)
            ?? ""
        let multiSelect = (dictionary["multiSelect"] as? Bool)
            ?? (dictionary["multi_select"] as? Bool)
            ?? false
        let rawOptions = dictionary["options"] as? [Any] ?? []
        let options = rawOptions.enumerated().compactMap { index, raw -> WorkstreamQuestionOption? in
            if let label = raw as? String {
                return WorkstreamQuestionOption(id: "opt\(index)", label: label)
            }
            guard let option = raw as? [String: Any] else { return nil }
            let id = (option["id"] as? String) ?? "opt\(index)"
            let label = (option["label"] as? String) ?? (option["title"] as? String) ?? id
            let description = (option["description"] as? String) ?? (option["detail"] as? String)
            return WorkstreamQuestionOption(id: id, label: label, description: description)
        }
        return WorkstreamQuestionPrompt(
            id: (dictionary["id"] as? String) ?? fallbackId,
            header: header,
            prompt: prompt,
            multiSelect: multiSelect,
            options: options
        )
    }
}
