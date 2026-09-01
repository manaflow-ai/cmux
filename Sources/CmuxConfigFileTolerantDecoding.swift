import Foundation

struct CmuxConfigActionDecodeIssue: Equatable, Sendable {
    let path: String
    let message: String
}

struct CmuxConfigFileDecodeResult: Sendable {
    let config: CmuxConfigFile
    let actionIssues: [CmuxConfigActionDecodeIssue]
}

extension CmuxConfigFile {
    /// Decode a config while isolating malformed entries in the `actions` map.
    ///
    /// The ordinary `Codable` decoder remains strict. This entry point is used
    /// by the config store so one bad action cannot hide otherwise valid
    /// actions, while errors in the rest of the file still reject the file.
    static func decodeToleratingInvalidActions(
        from data: Data
    ) throws -> CmuxConfigFileDecodeResult {
        do {
            let config = try decodeConfig(data: data)
            return CmuxConfigFileDecodeResult(config: config, actionIssues: [])
        } catch {
            let originalError = error
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawActions = root["actions"] as? [String: Any] else {
                throw originalError
            }
            // Validate the action map before dropping any malformed values.
            // Otherwise an invalid entry could conceal a duplicate normalized
            // ID or built-in alias that the strict decoder must reject.
            guard actionMapCanBeNormalized(rawActions) else { throw originalError }

            var validActions = [String: Any]()
            var actionIssues = [CmuxConfigActionDecodeIssue]()
            for actionID in rawActions.keys {
                guard let rawAction = rawActions[actionID] as? [String: Any] else {
                    actionIssues.append(
                        CmuxConfigActionDecodeIssue(
                            path: "actions.\(actionID)",
                            message: "must be a JSON object"
                        )
                    )
                    continue
                }
                do {
                    let actionData = try JSONSerialization.data(withJSONObject: rawAction)
                    _ = try decodeAction(data: actionData)
                    validActions[actionID] = rawAction
                } catch {
                    actionIssues.append(
                        CmuxConfigActionDecodeIssue(
                            path: actionIssuePath(actionID: actionID, error: error),
                            message: decodingMessage(error)
                        )
                    )
                }
            }

            // A failure outside an individual action (for example, malformed
            // commands or duplicate normalized IDs) must retain strict file
            // rejection rather than silently weakening validation.
            guard !actionIssues.isEmpty else { throw originalError }
            root["actions"] = validActions
            do {
                let partialData = try JSONSerialization.data(withJSONObject: root)
                let config = try decodeConfig(data: partialData)
                return CmuxConfigFileDecodeResult(config: config, actionIssues: actionIssues)
            } catch {
                throw originalError
            }
        }
    }

    private static func decodeConfig(data: Data) throws -> CmuxConfigFile {
        let decoder = JSONDecoder()
        return try decoder.decode(CmuxConfigFile.self, from: data)
    }

    private static func decodeAction(data: Data) throws -> CmuxConfigActionDefinition {
        let decoder = JSONDecoder()
        return try decoder.decode(CmuxConfigActionDefinition.self, from: data)
    }

    private static func actionMapCanBeNormalized(_ actions: [String: Any]) -> Bool {
        var normalizedIDs = Set<String>()
        var canonicalIDs = Set<String>()
        let catalog = CmuxConfigBuiltInActionCatalog()
        for rawID in actions.keys {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, normalizedIDs.insert(id).inserted else { return false }
            let canonicalID = catalog.canonicalID(for: id) ?? id
            guard canonicalIDs.insert(canonicalID).inserted else { return false }
        }
        return true
    }

    private static func actionIssuePath(actionID: String, error: Error) -> String {
        let codingPath: [CodingKey]
        switch error {
        case let DecodingError.dataCorrupted(context):
            codingPath = context.codingPath
        case let DecodingError.keyNotFound(key, context):
            codingPath = context.codingPath + [key]
        case let DecodingError.typeMismatch(_, context):
            codingPath = context.codingPath
        case let DecodingError.valueNotFound(_, context):
            codingPath = context.codingPath
        default:
            codingPath = []
        }
        var path = "actions.\(actionID)"
        for key in codingPath {
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += ".\(key.stringValue)"
            }
        }
        return path
    }

    private static func decodingMessage(_ error: Error) -> String {
        switch error {
        case let DecodingError.dataCorrupted(context):
            return context.debugDescription
        case let DecodingError.keyNotFound(_, context):
            return context.debugDescription
        case let DecodingError.typeMismatch(_, context):
            return context.debugDescription
        case let DecodingError.valueNotFound(_, context):
            return context.debugDescription
        default:
            return String(describing: error)
        }
    }
}
