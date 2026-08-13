import Foundation

/// One answer option in an AskUserQuestion payload.
public struct MobileWorkstreamQuestionOption: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, title, description, detail
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let label = try? single.decode(String.self) {
            let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Question option label must not be empty"
                )
            }
            id = normalized
            self.label = normalized
            description = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id)
        let decodedLabel = try (
            container.decodeIfPresent(String.self, forKey: .label)
                ?? container.decodeIfPresent(String.self, forKey: .title)
        )
        let resolvedLabel = decodedLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedLabel, !resolvedLabel.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Question option is missing a label")
            )
        }
        id = decodedID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? decodedID!
            : resolvedLabel
        label = resolvedLabel
        description = try (
            container.decodeIfPresent(String.self, forKey: .description)
                ?? container.decodeIfPresent(String.self, forKey: .detail)
        )
    }
}

/// One prompt in a multi-question AskUserQuestion request.
public struct MobileWorkstreamQuestion: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let header: String?
    public let prompt: String
    public let multiSelect: Bool
    public let options: [MobileWorkstreamQuestionOption]
    public let allowsOther: Bool?
    public let inputType: String?
    public let required: Bool?
    public let defaultValue: String?
    public let placeholder: String?
    public let externalURL: String?
    public let minimum: Double?
    public let maximum: Double?
    public let minLength: Int?
    public let maxLength: Int?
    public let minSelections: Int?
    public let maxSelections: Int?

    public init(
        id: String,
        header: String? = nil,
        prompt: String,
        multiSelect: Bool,
        options: [MobileWorkstreamQuestionOption],
        allowsOther: Bool? = nil,
        inputType: String? = nil,
        required: Bool? = nil,
        defaultValue: String? = nil,
        placeholder: String? = nil,
        externalURL: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minSelections: Int? = nil,
        maxSelections: Int? = nil
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.multiSelect = multiSelect
        self.options = options
        self.allowsOther = allowsOther
        self.inputType = inputType
        self.required = required
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.externalURL = externalURL
        self.minimum = minimum
        self.maximum = maximum
        self.minLength = minLength
        self.maxLength = maxLength
        self.minSelections = minSelections
        self.maxSelections = maxSelections
    }

    private enum CodingKeys: String, CodingKey {
        case id, header, prompt, question, title, description, options, required, placeholder
        case multiSelect = "multi_select"
        case multiSelectCamel = "multiSelect"
        case inputType = "input_type"
        case inputTypeCamel = "inputType"
        case defaultValue = "default_value"
        case defaultValueCamel = "defaultValue"
        case externalURL = "external_url"
        case externalURLCamel = "externalURL"
        case allowsOther = "allows_other"
        case allowsOtherCamel = "allowsOther"
        case isOther = "is_other"
        case isOtherCamel = "isOther"
        case minimum, maximum
        case minLength = "min_length"
        case minLengthCamel = "minLength"
        case maxLength = "max_length"
        case maxLengthCamel = "maxLength"
        case minSelections = "min_selections"
        case minSelectionsCamel = "minSelections"
        case maxSelections = "max_selections"
        case maxSelectionsCamel = "maxSelections"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(String.self, forKey: .id)
        id = decodedID
        header = try (
            container.decodeIfPresent(String.self, forKey: .header)
                ?? container.decodeIfPresent(String.self, forKey: .title)
        )
        let decodedPrompt = try (
            container.decodeIfPresent(String.self, forKey: .prompt)
                ?? container.decodeIfPresent(String.self, forKey: .question)
        )
        let decodedPlaceholder = try (
            container.decodeIfPresent(String.self, forKey: .placeholder)
                ?? container.decodeIfPresent(String.self, forKey: .description)
        )
        prompt = decodedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? decodedPrompt!
            : (decodedPlaceholder?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? decodedPlaceholder!
                : decodedID)
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect)
            ?? container.decodeIfPresent(Bool.self, forKey: .multiSelectCamel)
            ?? false
        options = try container.decodeIfPresent([MobileWorkstreamQuestionOption].self, forKey: .options) ?? []
        inputType = try container.decodeIfPresent(String.self, forKey: .inputType)
            ?? container.decodeIfPresent(String.self, forKey: .inputTypeCamel)
        required = try container.decodeIfPresent(Bool.self, forKey: .required)
        allowsOther = try container.decodeIfPresent(Bool.self, forKey: .allowsOther)
            ?? container.decodeIfPresent(Bool.self, forKey: .allowsOtherCamel)
            ?? container.decodeIfPresent(Bool.self, forKey: .isOther)
            ?? container.decodeIfPresent(Bool.self, forKey: .isOtherCamel)
        defaultValue = try Self.decodeScalarString(container, forKey: .defaultValue)
            ?? Self.decodeScalarString(container, forKey: .defaultValueCamel)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        externalURL = try container.decodeIfPresent(String.self, forKey: .externalURL)
            ?? container.decodeIfPresent(String.self, forKey: .externalURLCamel)
        minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
        minLength = try container.decodeIfPresent(Int.self, forKey: .minLength)
            ?? container.decodeIfPresent(Int.self, forKey: .minLengthCamel)
        maxLength = try container.decodeIfPresent(Int.self, forKey: .maxLength)
            ?? container.decodeIfPresent(Int.self, forKey: .maxLengthCamel)
        minSelections = try container.decodeIfPresent(Int.self, forKey: .minSelections)
            ?? container.decodeIfPresent(Int.self, forKey: .minSelectionsCamel)
        maxSelections = try container.decodeIfPresent(Int.self, forKey: .maxSelections)
            ?? container.decodeIfPresent(Int.self, forKey: .maxSelectionsCamel)
    }

    private static func decodeScalarString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        if let value = try container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: key) { return value ? "true" : "false" }
        if let value = try container.decodeIfPresent(Double.self, forKey: key) {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        return nil
    }
}

/// Forward-compatible typed presentation payload for one workstream event.
public enum MobileWorkstreamFeedPayload: Equatable, Sendable {
    case permission(requestID: String, toolName: String, safeInput: String, supportedModes: [String])
    case exitPlan(requestID: String, plan: String, summary: String?, defaultMode: String)
    case question(requestID: String, questions: [MobileWorkstreamQuestion])
    /// A yes/no or confirmation primitive. It uses the same authoritative
    /// question reply channel as AskUserQuestion, but renders a dedicated
    /// two-choice control on mobile.
    case boolean(
        requestID: String,
        prompt: String,
        yesLabel: String,
        noLabel: String,
        defaultValue: Bool?
    )
    /// A structured form or MCP elicitation request. Fields retain their
    /// input type so the client can render text, numeric, URL, secret, and
    /// choice controls without knowing the originating agent.
    case form(
        requestID: String,
        title: String?,
        fields: [MobileWorkstreamQuestion],
        externalURL: String?
    )
    case toolUse(name: String, input: String)
    case toolResult(name: String, result: String, isError: Bool)
    case message(text: String, fromUser: Bool)
    case stop(reason: String?)
    case todos
    case lifecycle
    case unknown(kind: String)
}
