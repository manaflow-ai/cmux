import Foundation

nonisolated enum GhosttyCrashReportMetadata {
    static func reportedExecutablePaths(in url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let event = sentryEvent(from: data),
              let debugMeta = event["debug_meta"] as? [String: Any],
              let images = debugMeta["images"] as? [[String: Any]]
        else {
            return nil
        }

        let paths = images.compactMap { image -> String? in
            guard let codeFile = image["code_file"] as? String else { return nil }
            let trimmedPath = codeFile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { return nil }
            return normalizedPath(trimmedPath)
        }
        return paths.isEmpty ? nil : Set(paths)
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func sentryEvent(from data: Data) -> [String: Any]? {
        guard let envelopeHeaderRange = lineRange(after: data.startIndex, in: data) else {
            return nil
        }

        var itemHeaderStart = data.index(after: envelopeHeaderRange.upperBound)
        while itemHeaderStart < data.endIndex {
            guard let itemHeaderRange = lineRange(after: itemHeaderStart, in: data),
                  let itemHeader = jsonObject(in: itemHeaderRange, from: data)
            else {
                return nil
            }

            let payloadStart = data.index(after: itemHeaderRange.upperBound)
            let payloadRange: Range<Data.Index>
            if let length = itemHeader["length"] as? Int {
                guard length >= 0,
                      let payloadEnd = data.index(payloadStart, offsetBy: length, limitedBy: data.endIndex)
                else {
                    return nil
                }
                payloadRange = payloadStart..<payloadEnd
                itemHeaderStart = payloadEnd
                if itemHeaderStart < data.endIndex, data[itemHeaderStart] == 0x0A {
                    itemHeaderStart = data.index(after: itemHeaderStart)
                }
            } else {
                guard let lineRange = lineRange(after: payloadStart, in: data) else {
                    return nil
                }
                payloadRange = lineRange
                itemHeaderStart = data.index(after: lineRange.upperBound)
            }

            if itemHeader["type"] as? String == "event" {
                return jsonObject(in: payloadRange, from: data)
            }
        }

        return nil
    }

    private static func lineRange(after startIndex: Data.Index, in data: Data) -> Range<Data.Index>? {
        guard startIndex < data.endIndex,
              let newlineIndex = data[startIndex...].firstIndex(of: 0x0A)
        else {
            return nil
        }
        return startIndex..<newlineIndex
    }

    private static func jsonObject(in range: Range<Data.Index>, from data: Data) -> [String: Any]? {
        guard range.lowerBound <= range.upperBound else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data.subdata(in: range)) else {
            return nil
        }
        return object as? [String: Any]
    }
}
