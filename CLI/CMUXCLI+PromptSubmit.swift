import Foundation

extension CMUXCLI {
    /// Counts original Unicode grapheme clusters, or reads the count captured
    /// before hook compaction. Empty prompts retain a count even without a preview.
    func feedPromptLength(from object: [String: Any]?, compacted: Bool) -> Int? {
        guard let object else { return nil }
        let containers = [object] + ["notification", "data"].compactMap { object[$0] as? [String: Any] }
        // Match feedPromptText's first nonempty message before considering an empty prompt.
        for container in containers {
            for key in Self.hookMessageLengthKeys {
                guard let text = container[key] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                return compacted ? container["\(key)_length"] as? Int : text.count
            }
        }
        for container in containers {
            for key in Self.hookMessageLengthKeys {
                if compacted, let length = container["\(key)_length"] as? Int { return length }
                if !compacted, let text = container[key] as? String { return text.count }
            }
        }
        return nil
    }
}
