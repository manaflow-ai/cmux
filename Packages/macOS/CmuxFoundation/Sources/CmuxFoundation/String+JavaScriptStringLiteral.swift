import Foundation

public extension String {
    /// This string encoded as a quoted JavaScript string literal, ready to splice into JS source.
    ///
    /// The value includes the surrounding double quotes and escapes any characters (quotes,
    /// backslashes, control characters) that would otherwise break out of the literal. Encoding
    /// goes through `JSONSerialization`, so the result is also a valid JSON string.
    ///
    /// ```swift
    /// "a\"b".javaScriptStringLiteral                       // -> "\"a\\\"b\""
    /// webView.evaluateJavaScript("setValue(\(id?.javaScriptStringLiteral ?? "null"))")
    /// ```
    ///
    /// - Returns: The quoted JS string literal, or `nil` if the string cannot be encoded.
    var javaScriptStringLiteral: String? {
        // [self] is always valid JSON; reuse JSON's escaping and drop the array brackets to
        // get a quoted JS string literal.
        guard let data = try? JSONSerialization.data(withJSONObject: [self]),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else {
            return nil
        }
        return String(arrayLiteral.dropFirst().dropLast())
    }
}
