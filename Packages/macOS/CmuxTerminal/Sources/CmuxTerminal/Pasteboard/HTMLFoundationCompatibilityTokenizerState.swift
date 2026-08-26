/// The subset of HTML tokenizer states needed to distinguish tag syntax from
/// slashes embedded in attribute values.
enum HTMLFoundationCompatibilityTokenizerState: Sendable {
    case beforeAttributeName
    case attributeName
    case afterAttributeName
    case beforeAttributeValue
    case doubleQuotedAttributeValue
    case singleQuotedAttributeValue
    case unquotedAttributeValue
    case afterQuotedAttributeValue
}
