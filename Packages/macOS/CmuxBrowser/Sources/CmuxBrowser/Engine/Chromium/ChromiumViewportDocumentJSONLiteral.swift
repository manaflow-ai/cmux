import Foundation

/// Encodes native text for safe interpolation into the local viewport document.
struct ChromiumViewportDocumentJSONLiteral {
    func encode(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let result = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return result
    }
}
