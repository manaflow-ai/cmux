public import Foundation

/// Pure parsers for provider command and configuration output.
public struct MobileTaskModelParser: Sendable {
    /// Creates a model parser.
    public init() {}

    /// Parses `opencode models --verbose`, where each provider-qualified ID is
    /// followed by one pretty-printed JSON object. Variant keys are effort
    /// choices for that exact model.
    public func openCodeModels(from output: String) -> [MobileTaskModel] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var models: [MobileTaskModel] = []
        var lineIndex = 0
        while lineIndex < lines.count {
            let id = lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            lineIndex += 1
            guard !id.isEmpty, lineIndex < lines.count,
                  lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
            else { continue }
            var objectLines: [Substring] = []
            var depth = 0
            var hasStarted = false
            var isInString = false
            var isEscaped = false
            while lineIndex < lines.count {
                let line = lines[lineIndex]
                objectLines.append(line)
                lineIndex += 1
                for character in line {
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\", isInString {
                        isEscaped = true
                    } else if character == "\"" {
                        isInString.toggle()
                    } else if !isInString, character == "{" {
                        depth += 1
                        hasStarted = true
                    } else if !isInString, character == "}" {
                        depth -= 1
                    }
                }
                if hasStarted, depth == 0 { break }
            }
            guard let data = objectLines.joined(separator: "\n").data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let name = (object["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let variants = object["variants"] as? [String: Any] ?? [:]
            let efforts = variants.keys
                .sorted(by: Self.effortPrecedes)
                .compactMap(Self.effort(from:))
            models.append(MobileTaskModel(
                id: id,
                displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                efforts: efforts
            ))
        }
        return uniqueModels(models)
    }

    /// Parses Claude Code's control-stream `list_models` response.
    ///
    /// The synthetic `default` choice is omitted because the composer already
    /// represents provider-default behavior with no explicit model flag.
    public func claudeModels(from output: String) -> [MobileTaskModel] {
        claudeModelList(from: output).models
    }

    /// Parses the implicit provider-default choice from Claude Code's
    /// control-stream catalog. Claude reports this as a synthetic `default`
    /// row, which must remain metadata rather than an explicit picker item.
    public func claudeDefaultModel(from output: String) -> MobileTaskModel? {
        claudeModelList(from: output).defaultModel
    }

    private func claudeModelList(
        from output: String
    ) -> (models: [MobileTaskModel], defaultModel: MobileTaskModel?) {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  object["type"] as? String == "control_response",
                  let response = object["response"] as? [String: Any],
                  response["subtype"] as? String == "success",
                  response["request_id"] as? String == "cmux-list-options",
                  let payload = response["response"] as? [String: Any],
                  let rawModels = payload["models"] as? [[String: Any]] else {
                continue
            }
            let parsedModels = rawModels.compactMap(Self.claudeModel(from:))
            let models = uniqueModels(parsedModels.filter { $0.id.lowercased() != "default" })
            let defaultModel = parsedModels.first { $0.id.lowercased() == "default" }
            return (models, defaultModel)
        }
        return ([], nil)
    }

    private static func claudeModel(from raw: [String: Any]) -> MobileTaskModel? {
        guard let rawID = raw["value"] as? String else { return nil }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let rawName = raw["displayName"] as? String
        let displayName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let efforts = (raw["supportedEffortLevels"] as? [String] ?? [])
            .compactMap(Self.effort(from:))
        let defaultEffortID = (raw["defaultEffortLevel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MobileTaskModel(
            id: id,
            displayName: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? id,
            efforts: efforts,
            defaultEffortID: defaultEffortID
        )
    }

    /// Parses Codex's model catalog JSON.
    ///
    /// - Parameter output: Standard output from `codex debug models`.
    /// - Returns: Listed model identifiers with display names in upstream order.
    public func codexModels(from output: String) -> [MobileTaskModel] {
        guard let data = output.data(using: .utf8) else { return [] }
        return codexModels(from: data)
    }

    /// Parses the model catalog downloaded and owned by Codex itself.
    public func codexModels(from data: Data) -> [MobileTaskModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rawModels = object["models"] as? [[String: Any]] else {
            return []
        }
        return uniqueModels(rawModels.compactMap { raw in
            guard raw["visibility"] as? String == "list",
                  let rawID = raw["slug"] as? String else { return nil }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let rawName = raw["display_name"] as? String
            let displayName = rawName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let efforts = (raw["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                .compactMap { rawEffort -> MobileTaskModelEffort? in
                    guard let value = rawEffort["effort"] as? String,
                          let effort = Self.effort(from: value) else { return nil }
                    let description = (rawEffort["description"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return MobileTaskModelEffort(
                        id: effort.id,
                        displayName: effort.displayName,
                        description: description.flatMap { $0.isEmpty ? nil : $0 }
                    )
                }
            let defaultEffortID = (raw["default_reasoning_level"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MobileTaskModel(
                id: id,
                displayName: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                efforts: efforts,
                defaultEffortID: defaultEffortID
            )
        })
    }

    /// Parses a top-level quoted `model = "..."` assignment from Codex TOML.
    ///
    /// - Parameter data: UTF-8 contents of `~/.codex/config.toml`.
    /// - Returns: The configured nonblank model identifier, if present.
    public func codexConfiguredModel(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // A TOML table header changes the scope for every following key.
            // The configured default we want is only valid before that point.
            if trimmed.hasPrefix("[") {
                return nil
            }
            guard !trimmed.hasPrefix("#"),
                  let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "model"
            else {
                continue
            }
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.first == "\"",
                  let closingQuote = value.dropFirst().firstIndex(of: "\"")
            else {
                return nil
            }
            let model = value[value.index(after: value.startIndex)..<closingQuote]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? nil : model
        }
        return nil
    }

    /// Parses the top-level `model` string from Claude settings JSON.
    ///
    /// - Parameter data: Contents of `~/.claude/settings.json`.
    /// - Returns: The configured nonblank model identifier, if present.
    public func claudeConfiguredModel(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rawModel = object["model"] as? String else {
            return nil
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }

    private static func effort(from rawValue: String) -> MobileTaskModelEffort? {
        let id = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let words = id.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return MobileTaskModelEffort(id: id, displayName: words.capitalized)
    }

    /// Orders OpenCode's variant keys like the other providers' effort lists.
    /// OpenCode emits variants as a JSON object, so dictionary iteration does
    /// not carry the provider's intended low-to-max order into Swift.
    private static func effortPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let lhsRank = effortRank(lhs)
        let rhsRank = effortRank(rhs)
        guard lhsRank == rhsRank else { return lhsRank < rhsRank }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private static func effortRank(_ rawValue: String) -> Int {
        let normalized = rawValue
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "none": return 0
        case "low": return 1
        case "medium": return 2
        case "high": return 3
        case "xhigh": return 4
        case "max": return 5
        default: return 6
        }
    }

    private func uniqueModels(_ models: [MobileTaskModel]) -> [MobileTaskModel] {
        var seen: Set<String> = []
        return models.filter { seen.insert($0.id).inserted }
    }
}
