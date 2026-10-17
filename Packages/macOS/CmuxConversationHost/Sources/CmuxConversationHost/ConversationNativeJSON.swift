import CmuxConversation

extension ConversationJSONValue {
    var objectValue: [String: ConversationJSONValue]? { if case .object(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var numberValue: String? { if case .number(let value) = self { value } else { nil } }
    var stringOrNumber: String? { stringValue ?? numberValue }
}
