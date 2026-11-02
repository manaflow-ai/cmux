public import Foundation

/// Reads the items of a Sparkle appcast (RSS 2.0 with the `sparkle:` namespace) with the update
/// rules' parser (cmux-updater-core `updater_appcast_parse`): names as written, deltas skipped,
/// UTF-8 only; a document that is not well-formed or has no `<channel>` is an error.
nonisolated public enum AppcastParser {
    public static func parse(_ data: Data) throws -> [AppcastItem] {
        try parse(data, allowing: nil)
    }

    /// The items an updater that allows the `sparkle:channel` tags `channels` sees, in feed order
    /// (untagged items always; nil keeps every item).
    static func parse(_ data: Data, allowing channels: Set<String>?) throws -> [AppcastItem] {
        guard let xml = String(data: data, encoding: .utf8) else { throw AppcastParseError(message: "appcast is not UTF-8") }
        let request = AppcastParseRequest(xml: xml, allowedChannels: channels?.sorted())
        guard let answer: AppcastParseAnswer = UpdaterRules().call("updater_appcast_parse", json: request) else {
            throw AppcastParseError(message: "the update rules did not read the appcast")
        }
        if let error = answer.error { throw AppcastParseError(message: error) }
        return (answer.items ?? []).map(\.item)
    }
}

nonisolated private struct AppcastParseRequest: Encodable {
    var xml: String
    var allowedChannels: [String]?
}

nonisolated private struct AppcastParseAnswer: Decodable {
    var items: [AppcastItem.Wire]?
    var error: String?
}
