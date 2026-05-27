import Foundation

nonisolated struct DockConfigFile: Codable, Sendable {
    let controls: [DockControlDefinition]
}

nonisolated enum DockConfigFileLocator {
    static func existingConfigURL(in directory: URL) -> URL? {
        let jsonURL = directory.appendingPathComponent("dock.json", isDirectory: false)
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            return jsonURL
        }
        let jsoncURL = directory.appendingPathComponent("dock.jsonc", isDirectory: false)
        if FileManager.default.fileExists(atPath: jsoncURL.path) {
            return jsoncURL
        }
        return nil
    }
}

nonisolated enum DockConfigParser {
    /// Decodes Dock controls from a JSONC configuration payload.
    static func decodeControls(data: Data) throws -> [DockControlDefinition] {
        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            let reason = parseFailureReason(for: error)
            throw NSError(
                domain: "cmux.dock",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "dock.error.jsoncParseFailed",
                        defaultValue: "Couldn't parse Dock config as JSONC: \(reason)."
                    ),
                    NSLocalizedRecoverySuggestionErrorKey: String(
                        localized: "dock.error.jsoncParseFailed.recovery",
                        defaultValue: "Check comments and trailing commas in your Dock config file, then reload Dock."
                    ),
                    NSUnderlyingErrorKey: error,
                ]
            )
        }
        return try JSONDecoder().decode(DockConfigFile.self, from: sanitized).controls
    }

    private static func parseFailureReason(for error: Error) -> String {
        switch error {
        case JSONCParser.JSONCError.unterminatedBlockComment:
            return String(
                localized: "dock.error.jsoncParseFailed.reason.unterminatedBlockComment",
                defaultValue: "an unterminated block comment"
            )
        case JSONCParser.JSONCError.invalidTrailingComma:
            return String(
                localized: "dock.error.jsoncParseFailed.reason.trailingComma",
                defaultValue: "an invalid trailing comma"
            )
        case JSONCParser.JSONCError.invalidTextEncoding:
            return String(
                localized: "dock.error.jsoncParseFailed.reason.encoding",
                defaultValue: "an unsupported text encoding"
            )
        default:
            return String(
                localized: "dock.error.jsoncParseFailed.reason.syntax",
                defaultValue: "invalid syntax"
            )
        }
    }
}
