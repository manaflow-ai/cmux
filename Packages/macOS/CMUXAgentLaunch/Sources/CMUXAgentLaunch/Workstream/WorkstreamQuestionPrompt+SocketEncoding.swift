import Foundation

extension WorkstreamQuestionPrompt {
    /// The `[String: Any]` JSON shape the `feed.*` socket handlers emit for one
    /// question prompt. Byte-faithful port of the legacy
    /// `FeedSocketEncoding.questionDict`.
    var socketEncodedDictionary: [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "multi_select": multiSelect,
        ]
        if let header {
            dict.assignFeedSocketTruncated(header, key: "header", limit: String.feedSocketSecondaryTextLimit)
        }
        dict.assignFeedSocketTruncated(prompt, key: "prompt", limit: String.feedSocketPrimaryTextLimit)
        dict["options"] = options.map { option in
            var optionDict: [String: Any] = [
                "id": option.id,
                "label": option.label.feedSocketTruncated(limit: String.feedSocketSecondaryTextLimit).text,
            ]
            if let description = option.description {
                optionDict.assignFeedSocketTruncated(description, key: "description", limit: String.feedSocketSecondaryTextLimit)
            }
            return optionDict
        }
        return dict
    }
}
