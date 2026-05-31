import Foundation

public enum FileExtensionOpenBehavior: String, CaseIterable, Identifiable, Sendable, SettingCodable {
    case automatic
    case cmuxPreview
    case markdownViewer
    case cmuxBrowser
    case preferredEditor
    case systemDefault

    public var id: String { rawValue }

    public static let defaultOpeners: [String: FileExtensionOpenBehavior] = [
        "htm": .cmuxBrowser,
        "html": .cmuxBrowser,
    ]

    public static func normalizedExtension(_ rawValue: String) -> String? {
        var trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ character in
                  character.isLetter || character.isNumber || character == "-" || character == "_" || character == "+"
              }) else {
            return nil
        }
        return trimmed
    }
}
