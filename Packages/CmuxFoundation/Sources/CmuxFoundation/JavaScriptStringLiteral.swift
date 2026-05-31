import Foundation

/// Encodes a string as a quoted JavaScript string literal, ready to splice into JS source.
///
/// The returned value includes the surrounding double quotes and escapes any characters
/// (quotes, backslashes, control characters) that would otherwise break out of the literal.
/// Encoding goes through `JSONSerialization`, so the result is also a valid JSON string.
///
/// ```swift
/// cmuxJavaScriptStringLiteral("a\"b")   // -> "\"a\\\"b\""
/// cmuxJavaScriptStringLiteral(nil)      // -> nil
/// ```
///
/// - Parameter value: The raw string to encode, or `nil`.
/// - Returns: The quoted JS string literal, or `nil` when `value` is `nil` or cannot be encoded.
public func cmuxJavaScriptStringLiteral(_ value: String?) -> String? {
    guard let value else { return nil }
    // Serialize as a JSON array, then strip the outer brackets to get a quoted JS string literal.
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let arrayLiteral = String(data: data, encoding: .utf8),
          arrayLiteral.count >= 2 else {
        return nil
    }
    return String(arrayLiteral.dropFirst().dropLast())
}
