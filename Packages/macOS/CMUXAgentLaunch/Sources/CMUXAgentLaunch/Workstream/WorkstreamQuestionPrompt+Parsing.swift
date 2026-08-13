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
        if let fields = root["fields"] as? [[String: Any]] {
            return fields.enumerated().map { index, field in
                makeParsedQuestion(from: field, fallbackId: "field\(index)", formField: true)
            }
        }
        let schema = (root["schema"] as? [String: Any])
            ?? (root["requestedSchema"] as? [String: Any])
            ?? (root["requested_schema"] as? [String: Any])
            ?? root
        if let properties = schema["properties"] as? [String: Any] {
            let required = Set(schema["required"] as? [String] ?? [])
            return properties.keys.sorted().enumerated().compactMap { index, key in
                guard var field = properties[key] as? [String: Any] else { return nil }
                field["id"] = key
                field["required"] = required.contains(key)
                return makeParsedQuestion(from: field, fallbackId: "field\(index)", formField: true)
            }
        }
        return [makeParsedQuestion(from: root, fallbackId: "q0")]
    }

    private static func makeParsedQuestion(
        from dictionary: [String: Any],
        fallbackId: String,
        formField: Bool = false
    ) -> WorkstreamQuestionPrompt {
        let header = (dictionary["header"] as? String) ?? (dictionary["title"] as? String)
        let prompt = (dictionary["question"] as? String)
            ?? (dictionary["prompt"] as? String)
            ?? (dictionary["title"] as? String)
            ?? (dictionary["description"] as? String)
            ?? (dictionary["message"] as? String)
            ?? (dictionary["id"] as? String)
            ?? fallbackId
        let declaredType = (dictionary["input_type"] as? String)
            ?? (dictionary["inputType"] as? String)
            ?? (dictionary["type"] as? String)
            ?? (dictionary["kind"] as? String)
        let multiSelect = (dictionary["multiSelect"] as? Bool)
            ?? (dictionary["multi_select"] as? Bool)
            ?? (dictionary["multiple"] as? Bool)
            ?? (declaredType?.lowercased() == "array")
        let items = dictionary["items"] as? [String: Any]
        let rawOptions: [Any]
        let enumNames: [String]?
        if let options = dictionary["options"] as? [Any] {
            rawOptions = options
            enumNames = nil
        } else if let values = dictionary["oneOf"] as? [Any] {
            rawOptions = values
            enumNames = nil
        } else if let values = items?["anyOf"] as? [Any] {
            rawOptions = values
            enumNames = nil
        } else if let values = dictionary["enum"] as? [Any] {
            rawOptions = values
            enumNames = dictionary["enumNames"] as? [String]
        } else if let values = items?["enum"] as? [Any] {
            rawOptions = values
            enumNames = items?["enumNames"] as? [String]
        } else {
            rawOptions = []
            enumNames = nil
        }
        let options = rawOptions.enumerated().compactMap { index, raw -> WorkstreamQuestionOption? in
            if let scalar = scalarString(raw) {
                return WorkstreamQuestionOption(
                    id: "opt\(index)",
                    label: enumNames?[safe: index] ?? scalar
                )
            }
            guard let option = raw as? [String: Any] else { return nil }
            let constant = option["const"].flatMap(scalarString)
            let id = (option["id"] as? String)
                ?? (option["value"] as? String)
                ?? constant
                ?? "opt\(index)"
            let label = (option["label"] as? String) ?? (option["title"] as? String) ?? id
            let description = (option["description"] as? String) ?? (option["detail"] as? String)
            return WorkstreamQuestionOption(id: id, label: label, description: description)
        }
        let formatType: String? = {
            guard let format = dictionary["format"] as? String else { return nil }
            switch format.lowercased() {
            case "url", "uri", "uri-reference": return "url"
            case "email": return "email"
            case "date": return "date"
            case "date-time", "datetime": return "date_time"
            case "password", "secret": return "secret"
            default: return nil
            }
        }()
        let rawType: String? = {
            if let declaredType {
                if !options.isEmpty,
                   ["array", "string", "number", "integer"].contains(declaredType.lowercased()) {
                    return "choice"
                }
                if declaredType.lowercased() == "string", let formatType {
                    return formatType
                }
                return declaredType
            }
            if let formatType {
                return formatType
            }
            return (dictionary["isSecret"] as? Bool) == true
                || (dictionary["writeOnly"] as? Bool) == true ? "secret" : nil
        }()
        let normalizedType = rawType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inputType: WorkstreamQuestionInputType?
        switch normalizedType {
        case "boolean", "bool", "confirmation", "confirm", "yes_no":
            inputType = .boolean
        case "text", "string", "textarea":
            inputType = .text
        case "number", "decimal":
            inputType = .number
        case "integer", "int":
            inputType = .integer
        case "url", "uri":
            inputType = .url
        case "email":
            inputType = .email
        case "date":
            inputType = .date
        case "date_time", "datetime", "date-time":
            inputType = .dateTime
        case "secret", "password":
            inputType = .secret
        case "external", "external_url", "link":
            inputType = .external
        case "choice", "select", "enum", "radio", "multiselect", "multi_select":
            inputType = .choice
        default:
            inputType = formField ? .text : nil
        }
        var resolvedOptions = options
        if inputType == .boolean, resolvedOptions.isEmpty {
            resolvedOptions = [
                WorkstreamQuestionOption(
                    id: "yes",
                    label: String(localized: "feed.question.boolean.yes", defaultValue: "Yes")
                ),
                WorkstreamQuestionOption(
                    id: "no",
                    label: String(localized: "feed.question.boolean.no", defaultValue: "No")
                ),
            ]
        }
        let rawDefaultValue: String?
        if let value = dictionary["default"] as? String {
            rawDefaultValue = value
        } else if let value = dictionary["default_value"] as? String {
            rawDefaultValue = value
        } else if let value = dictionary["default"] as? NSNumber {
            rawDefaultValue = value.stringValue
        } else {
            rawDefaultValue = nil
        }
        let defaultValue: String? = rawDefaultValue.map { value in
            guard inputType == .choice else { return value }
            if let option = resolvedOptions.first(where: { $0.id == value || $0.label == value }) {
                return option.id
            }
            if let index = rawOptions.firstIndex(where: { raw in
                if let dictionary = raw as? [String: Any], let constant = dictionary["const"] {
                    return scalarString(constant) == value
                }
                return scalarString(raw) == value
            }), resolvedOptions.indices.contains(index) {
                return resolvedOptions[index].id
            }
            return value
        }
        let explicitAllowsOther = (dictionary["isOther"] as? Bool)
            ?? (dictionary["is_other"] as? Bool)
            ?? (dictionary["allowsOther"] as? Bool)
            ?? (dictionary["allows_other"] as? Bool)
            ?? (dictionary["custom"] as? Bool)
        let allowsOther = explicitAllowsOther ?? (formField && !resolvedOptions.isEmpty ? false : nil)
        return WorkstreamQuestionPrompt(
            id: (dictionary["id"] as? String) ?? fallbackId,
            header: header,
            prompt: prompt,
            multiSelect: multiSelect,
            options: resolvedOptions,
            allowsOther: allowsOther,
            inputType: inputType,
            required: dictionary["required"] as? Bool,
            defaultValue: defaultValue,
            placeholder: (dictionary["placeholder"] as? String)
                ?? (dictionary["description"] as? String),
            externalURL: (dictionary["url"] as? String)
                ?? (dictionary["uri"] as? String)
                ?? (dictionary["external_url"] as? String)
                ?? (dictionary["externalURL"] as? String),
            minimum: (dictionary["minimum"] as? NSNumber)?.doubleValue,
            maximum: (dictionary["maximum"] as? NSNumber)?.doubleValue,
            minLength: (dictionary["minLength"] as? NSNumber)?.intValue,
            maxLength: (dictionary["maxLength"] as? NSNumber)?.intValue,
            minSelections: (dictionary["minItems"] as? NSNumber)?.intValue,
            maxSelections: (dictionary["maxItems"] as? NSNumber)?.intValue
        )
    }

    private static func scalarString(_ raw: Any) -> String? {
        if let value = raw as? String { return value }
        if let value = raw as? Bool { return value ? "true" : "false" }
        if let value = raw as? NSNumber { return value.stringValue }
        return nil
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
